import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../widgets/disabled_reason.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/errors/failure_message.dart';
import '../../../core/errors/guarded_write.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/computation_status_provider.dart';
import '../../../core/providers/gps_provider.dart';
import '../../../core/providers/map_settings_provider.dart';
import '../../../core/providers/navigation_target_provider.dart';
import '../../../core/providers/recordings_revision_provider.dart';
import '../../../core/providers/shared_observation_preview_provider.dart';
import '../../../core/providers/terrain_cache_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/estimate_bearing_resolution.dart';
import '../widgets/map_pin_marker.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import '../../../data/models/actual_tag_location.dart';
import '../../../data/models/deployment.dart';
import '../../../data/models/observation.dart';
import '../../../data/models/user.dart';
import '../../../data/models/project.dart';
import '../../../data/repositories/deployment_repository.dart';
import '../../../data/repositories/mutation_authorization.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../data/sharing/gpx_writer.dart';
import '../../../data/sharing/map_handoff.dart';
import '../../../data/sharing/observation_share.dart';
import '../../../data/sharing/tritrack_copy.dart';
import '../../../core/format/coordinate_formatter.dart';
import '../../../core/format/observation_quality_display.dart';
import '../../../localization/coordinate_projection.dart';
import '../../../localization/few_bearings_caution.dart';
import '../../observations/widgets/observation_edit_dialog.dart';
import '../../observations/widgets/truth_point_edit_dialog.dart';
import '../../../viewshed/dem_tile_fetcher.dart';
import '../../../viewshed/dem_tile_store.dart';
import '../../../viewshed/viewshed.dart';
import '../../../viewshed/viewshed_overlay.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/sync_status_icon.dart';
import '../../../widgets/tag_color_swatch.dart';
import '../map_camera_target.dart';
import '../models/offline_region.dart';
import '../providers/offline_regions_provider.dart';
import '../services/bearing_wedge_cache.dart';
import '../services/cached_tile_provider.dart';
import '../services/desktop_map_gestures.dart';
import '../services/geo_math.dart';
import '../services/tile_sources.dart';
import '../widgets/elevation_profile_panel.dart';
import '../widgets/map_furniture.dart';

/// **A deadline on a computation, not on a request.**
///
/// This is one of the two `.timeout()` calls in `lib/` that survive task
/// 11.61's request-deadline policy, and
/// `test/documentation/request_deadline_allowlist_test.dart` holds the
/// reasoning: `computeViewshedInBackground` runs in an isolate on this device
/// and touches no server, so the policy that bounds every request has nothing
/// to say about it. What it guards against is a viewshed whose cost was
/// underestimated leaving "Computing viewshed…" on screen forever — the same
/// class of harm as a hung request, reached by an entirely different road.
const Duration kViewshedComputeDeadline = Duration(seconds: 20);

/// # SPACE BUDGET — read this before adding anything to this screen
///
/// **The subject of this screen is the map, and specifically the middle of
/// it.** Nothing here is laid out in a column, so no addition ever visibly
/// "pushes" anything — every overlay simply covers a little more of the thing
/// people came to look at, from an edge inward, and no individual addition
/// looks like a problem. That is exactly how the Position screen ended up
/// with **12 logical pixels** of unobstructed map (task 11.110, measuring
/// what task 11.109 had left alone), and this screen has more accreted
/// furniture than that one ever did.
///
/// So the number that is measured and asserted is **the tallest horizontal
/// band across the full width of the map with nothing drawn over it** —
/// `test/features/map/map_screen_space_budget_test.dart`. Not "how much
/// overlay is there": a control tucked in a corner still means the band it
/// sits in is not a band you can read a ray crossing in.
///
/// The rules:
///
/// 1. **The clear band is a floor, not a remainder.** Overlays get the
///    edges. If a new overlay would take the clear band below the floor, the
///    new overlay does not go on — find it a home in rule 3's list instead.
/// 2. **Measure with the warnings live, not in the calm state.** The screen
///    with nothing happening is not the screen people use. This screen adds a
///    shared-preview banner, a navigation panel, a computation progress bar,
///    a selection card and an elevation panel, and the sync status icon
///    appears above the "+" as soon as a server is configured. **A
///    conditional band appearing is the usual variable — not a list
///    growing.**
///
///    **The app shell used to be part of this arithmetic and is not any
///    more** (task 11.189): it put up to two banners above every tab, worth
///    ~76 logical pixels between them at the default text size and far more
///    at the accessibility sizes. They are gone, and this screen was handed
///    that space back. **That is headroom, not a licence** — rule 1 is
///    unchanged and the floor is unchanged.
/// 3. **Where new things go, in order of preference:** into the Layers &
///    Filters sheet; into an existing corner cluster (the right-hand button
///    column, the bottom-left readout column); into a card that appears only
///    while its mode is on. **A new permanent full-width band is the last
///    resort and needs the budget test re-run and its floor re-argued.**
/// 4. **Two things may not share one anchor.** Nothing in a `Stack` warns
///    you: the later child simply paints over the earlier one. The
///    navigation banner and the north arrow were both `left: 12, top: 56`
///    for months, so starting navigation on a rotated map hid the only
///    control that put the map back north-up. They are one column now.
///    **The bottom edge was the same story and was measured in task 11.126
///    item B:** the selection card, the measure readout, the elevation
///    profile and the computation progress bar were four separate anchors,
///    three of them at `bottom: 0` or `bottom: 12`, and at phone geometry
///    the selection card covered the "+" record button whole along with the
///    scale bar, the coordinate readout and the map-source credit. They are
///    **one transient column** now — keyed `map-bottom-panels`, keeping the
///    bottom edge, with the readout band, the "+" and the legend lifted
///    above it by that column's **measured** height. A new bottom panel is a
///    child of that column; it does not get an anchor of its own.
/// 5. **Onboarding copy never occupies permanent space** — it goes in the
///    legend card's footnote (see [MapLegendCard.footnote]), which is behind
///    the control people already press to ask what they are looking at.
/// 6. **Do not buy space by shrinking type or touch targets.** Field app,
///    gloves: 11pt text and 44pt targets are the floor.
///
/// **What holds this floor, and why it is an assertion rather than a layout
/// rule — task 11.166.**
///
/// Task 11.162 made the Offline Data Map's identical floor *structural*: a
/// `SizedBox` in the screen's own layout, so a fifth thing added there finds
/// the map protected and the cards squeezed. **That remedy is not available
/// here, and the reason is not that this is a `Stack`.** A render object
/// owning all six anchors could be written. The reason is that **a budget can
/// only ever say no by taking something away, and this screen has nothing it
/// may take.** Everything over this map is a licence condition (the map-source
/// credit), a control (the "+", the layer and location buttons, the north
/// arrow), or a warning about state (tiles not arriving, no GPS fix, a
/// navigation target running). Task 11.165's Record bar had a reassurance note
/// to spend; here the cheapest thing to withdraw is a warning, and a warning
/// withdrawn silently is a worse failure than the one the budget was
/// preventing. **So the floor is asserted, not enforced, and that is a
/// decision rather than an omission.**
///
/// **What was made structural instead is the check's own scope.**
/// `map_screen_space_budget_test.dart` used to measure a hand-written list of
/// seven overlay keys, under a comment asking the next person to add theirs.
/// **It was already wrong**: the legend card below has no key and was in no
/// list, so the floor was asserted only for the state where somebody has the
/// legend switched off — and a missing overlay makes the band read *larger*,
/// which is the silent direction. The set is now derived from this `Stack`'s
/// own children, so **a new overlay is measured whether or not anybody
/// remembers it**, and the derivation refuses to report a band at all if it
/// finds no overlays.
///
/// **Where the floor actually stands, re-measured by task 11.207 now that the
/// navigation banner has moved off the top-left column and into the bottom
/// panel** (and re-measured again the same day when that panel's row was
/// allowed to wrap — the two-line cap on it is a number this ladder chose,
/// see `ElevationProfilePanel`'s layout note) (sync status icon and a navigation target running, which is what
/// "everything live" means on this screen today): **512 logical pixels at the
/// default text size, 500 / 471 / 463 up the ordinary slider, 428 at AX1, 343
/// at AX2, 289 at AX3, 195 at AX4 — and 54 at AX5.** **It holds through the
/// whole ordinary slider and one accessibility stop past it, and loses it
/// above that**; `bandHoldsThrough` in the budget test (47/17, AX4) records
/// the last stop that holds, and above it the reason is the one the Position
/// screen's rule 1 gives — the map's own furniture outgrows the body, and no
/// layout on this screen can reach it. The tightest state at the default text
/// size is not the text-scale ladder at all: with tiles failing on a new
/// project and everything else live it is **274 against a floor of 96**.
///
/// **Every one of those numbers went up rather than down, and the reason is
/// worth keeping.** Task 11.207 added the climb and descent and gave
/// navigation a whole panel, which sounds like more furniture and is: what it
/// removed was a *second place* furniture could sit. The banner was a row in
/// the top-left column; the panel is a row in the bottom column, beside the
/// scale bar and the credit that were already there. **Two overlays on the
/// same edge cost the clear band once; two on opposite edges cost it twice**
/// — which is rule 4 measured rather than argued (the pre-11.207 numbers,
/// same states, were 438 at the default size and 121 at AX4).
///
/// **What task 11.103 added, and why it does not breach rule 5.** There is
/// now a sentence in the left-hand column saying the map does not know where
/// you are. It is not onboarding copy: it is the *state*, and it is the only
/// difference between "this map is showing open water because that is where
/// you are" and "this map is showing open water because nobody told it
/// anything". It occupies space only when there is no fix, nothing recorded
/// **and** no project extent — a new project's first minute — and it stacks
/// in the existing column rather than claiming an anchor of its own (rule 4).
/// Re-measured by task 11.207 with the sync status icon and navigation live
/// as well: **330 logical pixels of clear band, floor 96.**
///
/// **What task 11.131 added, and where it sits in these rules.** Dragging a
/// bearing's tip puts a pill on screen naming the length being drawn. It
/// takes no permanent space at all: it exists only while a finger is on the
/// handle, so it cannot appear in the calm state or in a warned one, and the
/// clear-band floor is unchanged. It is keyed `bearing-length-readout` and is
/// listed in the budget test's overlay set anyway — an overlay that is not in
/// that list is an overlay nobody would measure **if it later became
/// permanent**, which is the direction this kind of thing drifts. The grab
/// handle itself is drawn inside the map's own marker layer rather than as an
/// overlay, which is also why a handle clamped to the bottom edge has to be
/// kept clear of the bottom furniture by measurement — see `_tipHandlePoint`,
/// which since task 11.126 measures the whole transient bottom column rather
/// than the selection card alone, and so now clears the credit and the "+"
/// as well.
///
/// ---
///
/// Main Map: current location, bearing rays, estimated positions, ground-
/// truthed tag locations, the design doc's map-layer color scheme, and now
/// (Phase 5) a real offline-cacheable basemap and computed viewshed overlay.
///
/// Tiles are served through [CachedTileProvider] (disk cache first, network
/// fallback) rather than `flutter_map_tile_caching`, whose `latlong2`
/// constraint conflicts with the version pinned here. The tile *source* is
/// user-selectable (see [TileSources]) so the app stays deployable globally
/// under whichever free-licensed provider covers a given field site — see
/// the technical doc's "resolve early" licensing note.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _mapController = MapController();
  bool _predictMode = false;
  // Live viewshed: recompute from the current GPS fix as the user moves (e.g.
  // while driving), so the visible-terrain overlay follows them. Mutually
  // exclusive with tap-to-predict.
  bool _liveViewshed = false;
  bool _showViewshed = false;
  bool _showRays = true;
  bool _showWedges = true;
  bool _showEstimates = true;
  bool _showTagLocations = true;
  bool _showLegend = false;

  ViewshedResult? _viewshedResult;
  // Task 11.87 tried a vector-drawn boundary and then a vector-filled
  // polygon — a real device reported the vector fill as "extremely
  // laggy," so this is a flat raster PNG fill: baked once, then
  // GPU-sampled like any other texture, rather than several thousand
  // points re-projected and repainted every frame during pan/zoom. See
  // renderViewshedPng's doc comment and DEVELOPMENT_PLAN.md task 11.87's
  // addenda.
  Uint8List? _viewshedPng;
  ll.LatLng? _viewshedObserver;
  bool _viewshedBusy = false;
  double _observerHeightMeters = 1.7;
  double _viewshedOpacity = 0.6;
  bool _autoViewshedAttempted = false;
  bool _centeredOnce = false;
  Object? _centeredSharedIdentity;

  // Point-to-point measure tool (design doc "Map Furniture"). A third tap
  // after two points starts a fresh measurement rather than requiring an
  // explicit clear first.
  bool _measureMode = false;
  final List<ll.LatLng> _measurePoints = [];

  // Mirrors the FlutterMap camera so the north arrow/scale bar can read it
  // during build. MapController.camera throws until FlutterMap has completed
  // its first layout, so we can't read it directly from the controller.
  double _cameraRotation = 0;
  // Task 11.103: the *lat/lon readout's* seed, replaced by the camera target
  // on the first build with data. It was `LatLng(0, 0)`, so the readout at
  // the bottom of the map claimed the Gulf of Guinea for as long as the
  // project query took — the same defect as the camera's, one surface over,
  // and found by this task's standing guard rather than by anybody reading.
  ll.LatLng _cameraCenter = MapCameraTarget.worldViewCenter;
  double _cameraZoom = 14;
  bool _cameraSeeded = false;

  // The recording the user tapped on the map (bearing / estimate / tag
  // location), whose info shows in the bottom panel; null = nothing selected.
  _MapSelection? _selection;
  // Per-selection toggle for the selected estimate's error ellipse.
  bool _showSelectedEllipse = true;

  // ---------------------------------------------------------------------
  // How far a bearing is drawn (task 11.131)
  // ---------------------------------------------------------------------
  //
  // **One number, read by both layers.** The ray and the wedge used to carry
  // their own `400` literals and the comment above the wedge claimed it fanned
  // "out to the ray length" — true only because two constants happened to
  // match. They now read [_defaultBearingRangeMeters] and, once a bearing has
  // been dragged, the same per-observation entry in [_bearingRanges]. A ray
  // and its wedge disagreeing about how far a bearing reaches would be worse
  // than the fixed length this replaced.
  //
  // **Extending is honest, not decorative.** The wedge is an uncertainty
  // cone. Angular uncertainty does not shrink with distance, so a longer
  // wedge is a wider one, and that is the true picture — the cone is always
  // recomputed at the new range with the *same* half-angle
  // (`bearingWedgePoints` re-samples), never scaled or stretched.

  /// The length every bearing is drawn at until somebody drags it.
  static const double _defaultBearingRangeMeters = 400;

  /// The floor for a dragged length. Below this the wedge collapses to
  /// something too small to read a crossing off at any working zoom, and a
  /// bearing dragged to nothing looks like a bearing that was deleted.
  static const double _minBearingRangeMeters = 100;

  /// The ceiling for a dragged length: [kMaxBearingRangeMeters], 40 km —
  /// see that constant for where the number comes from. Since task 11.315 it
  /// is shared with the Record screen's *Take on map*, which draws every line
  /// out to it.
  ///
  /// Dragging past it **clamps** — the drag keeps working and the readout
  /// simply stops climbing, rather than the gesture refusing.
  static const double _maxBearingRangeMeters = kMaxBearingRangeMeters;

  /// Per-observation drawn length, in metres, for bearings that have been
  /// dragged. Absent = [_defaultBearingRangeMeters].
  ///
  /// **This is display state and nothing else.** It is never written to the
  /// row, never exported and never synced: a drawn length is a choice about
  /// what you are looking at, not a measurement, and putting it on the
  /// observation would turn a view preference into field data. It lives on
  /// this `State`, so it survives deselecting a bearing and selecting others
  /// — which is the whole point, since seeing where two wedges overlap needs
  /// both extended at once — and it is gone when the map screen is left,
  /// by construction rather than by a reset anybody has to remember to run.
  final Map<String, double> _bearingRanges = {};

  /// Memoised wedge polygons, so a drag recomputes only the bearing being
  /// dragged rather than every visible one. See [BearingWedgeCache].
  final BearingWedgeCache _wedgeCache = BearingWedgeCache();

  /// The bottom edge's three measured pieces (task 11.126 item B).
  ///
  /// **Everything anchored to the bottom of this screen is measured, not
  /// guessed.** Until task 11.126 the selection card, the elevation profile
  /// and the computation progress bar each claimed the bottom edge on their
  /// own, and a `Stack` says nothing when two children overlap — the later
  /// one simply paints over the earlier. Measured at phone geometry, the
  /// selection card covered the record button whole, the scale bar, the
  /// coordinate readout and the map-source credit; the progress bar covered
  /// the bottom of the elevation profile. See
  /// `test/features/map/map_screen_overlap_test.dart`.
  ///
  /// So there is now **one transient bottom column** ([_bottomPanelsKey]),
  /// and it sits above the two permanent things along that edge — the
  /// readout band and the "+" record button — by their **own rendered
  /// heights**. The band's height is not a constant: the map credit wraps to
  /// two lines on some tile sources, and the card's height depends on the
  /// row.
  final GlobalKey _bottomPanelsKey = GlobalKey();
  final GlobalKey _bottomBandKey = GlobalKey();
  final GlobalKey _recordFabKey = GlobalKey();

  /// Last known heights, in logical pixels, of the widgets above. Zero until
  /// the first frame that draws them.
  double _bottomPanelsHeight = 0;
  double _bottomBandHeight = 0;
  double _recordFabHeight = 0;

  /// A widget's rendered height, read off the widget itself.
  ///
  /// Deliberately via the render object rather than `Element.size`, which
  /// refuses to answer during build, and returning [previous] when the
  /// widget is not on screen. **The value can be one frame stale** — see
  /// [_rememberBottomGeometry], which asks for another frame when it changes,
  /// so a stale value survives for one frame and never longer.
  static double _measuredHeight(GlobalKey key, double previous) {
    final box = key.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) return box.size.height;
    return previous;
  }

  /// How far the permanent bottom furniture — the readout band on the left,
  /// the "+" record button on the right, the legend above it — is lifted by
  /// whatever transient panel is up, measured off that panel.
  ///
  /// **The transient column keeps the bottom edge and the furniture rides
  /// above it**, rather than the other way round. Both orders cost the same
  /// number of pixels, and the other one was tried first and is worse: it
  /// put roughly 300 logical pixels of furniture along the bottom of the map
  /// whenever anything was selected, and it pushed task 11.131's bearing
  /// grab handle — which is clamped to stay clear of all of it — back to
  /// within four pixels of the observation it belongs to, where it cannot be
  /// grabbed. A card riding above a bottom sheet is also the ordinary
  /// pattern; a scale bar that jumps is cheaper than a map that shrinks.
  double _bottomFurnitureLift() =>
      _bottomPanelsHeight > 0 ? _bottomPanelsHeight + 8 + 12 : 0;

  /// Where the bottom-right column — the sync status icon, when it is
  /// showing, and the "+" record button — stops, measured off the column
  /// itself, plus an 8-pixel gap. What the legend card has to clear.
  ///
  /// **The fallback is the height of the "+" alone**, which is what that
  /// column is in the state this screen opens in on a device with no server
  /// configured, and the smallest it is ever wrong by is one frame — see
  /// [_rememberBottomGeometry], which asks for another frame whenever the
  /// measurement moves.
  double _bottomRightColumnTop() =>
      20 + (_recordFabHeight > 0 ? _recordFabHeight : 56) + 8;

  /// Re-reads the three heights after a frame and asks for one more if any
  /// of them moved.
  ///
  /// Without this a panel that has just appeared would be laid out against
  /// last frame's numbers and stay there. The guard is the equality check:
  /// a frame in which nothing moved schedules nothing, so this cannot spin.
  void _rememberBottomGeometry() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final panels = _measuredHeight(_bottomPanelsKey, 0);
      final band = _measuredHeight(_bottomBandKey, _bottomBandHeight);
      final fab = _measuredHeight(_recordFabKey, _recordFabHeight);
      if ((panels - _bottomPanelsHeight).abs() < 0.5 &&
          (band - _bottomBandHeight).abs() < 0.5 &&
          (fab - _recordFabHeight).abs() < 0.5) {
        return;
      }
      setState(() {
        _bottomPanelsHeight = panels;
        _bottomBandHeight = band;
        _recordFabHeight = fab;
      });
    });
  }

  /// The observation whose tip is under the finger right now, and the length
  /// its drag started from. Non-null only during a drag.
  String? _tipDragObservationId;
  double _tipDragStartRangeMeters = _defaultBearingRangeMeters;

  /// The drawn length for one bearing: its dragged value, or the default.
  double _bearingRangeMeters(String observationId) =>
      _bearingRanges[observationId] ?? _defaultBearingRangeMeters;

  // Layers & filters (managed from the "Layers & Filters" bottom sheet).
  bool _showNonDetections = true;
  // Tags hidden from the map (empty = all visible); fights clutter over a
  // multi-day project. An equipment-level override: hiding a collar here
  // hides every one of its rays regardless of which animal (if any) covers
  // them.
  final Set<String> _hiddenTagIds = {};
  // Animals hidden from the map (empty = all visible) — task 11.247. Unlike
  // [_hiddenTagIds], this is asked per ray, not per collar: hiding Marie
  // hides only the rays a deployment says are hers, at the timestamp they
  // were taken, not every ray her collars have ever produced.
  final Set<String> _hiddenAnimalIds = {};
  // Only show recordings within this window (fights clutter as days accumulate).
  _MapTimeWindow _timeWindow = _MapTimeWindow.all;
  DateTimeRange? _customRange;

  /// Whether an element from [tagId], recorded at [at], should be drawn.
  ///
  /// Task 11.247: **the Map now answers "show me Marie" the way the Log
  /// does** — by asking which deployment covers this moment
  /// (`DeploymentRepository.animalForObservationIn`, the same derivation the
  /// Log uses, not a second one) — rather than by treating an animal filter
  /// as "every collar she has ever worn". A collar's own equipment-level
  /// hide ([_hiddenTagIds]) still overrides everything, whoever it belongs
  /// to at the time.
  ///
  /// **A ray with no covering deployment belongs to nobody** (design §2 —
  /// a collar that fell off still transmits) and is therefore never hidden
  /// by an animal checkbox; only its own collar checkbox can hide it.
  ///
  /// **A contested ray** — a moment two deployments both cover, design §4a,
  /// task 11.251 — stays drawn while *any* of its candidates is shown, and
  /// goes only when every one of them is hidden. Hiding Marie hides what is
  /// hers; a ray that might be Kea's is not hers to take with her.
  bool _visible(String? tagId, DateTime at, List<Deployment> deployments) {
    if (tagId == null) return true;
    if (_hiddenTagIds.contains(tagId)) return false;
    final attribution = DeploymentRepository.animalForObservationIn(
      deployments,
      tagId: tagId,
      at: at,
    );
    if (attribution.isNobody) return true;
    return !attribution.candidates.every(_hiddenAnimalIds.contains);
  }

  /// The project's animals that have a collar in the legend, each with its
  /// collars — derived from the two lists on every build of the sheet.
  List<_AnimalGroup> _animalGroupsOf(_MapData data) {
    final byAnimal = <String, List<_TagRow>>{};
    for (final t in data.tags) {
      for (final id in t.individualIds) {
        (byAnimal[id] ??= []).add(t);
      }
    }
    return [
      for (final animal in data.individuals)
        if (byAnimal.containsKey(animal.individualId))
          _AnimalGroup(animal, byAnimal[animal.individualId]!),
    ];
  }

  /// Collars no live animal of this project has ever worn.
  List<_TagRow> _ungroupedTags(_MapData data) {
    final live = {for (final a in data.individuals) a.individualId};
    return [
      for (final t in data.tags)
        if (!t.individualIds.any(live.contains)) t,
    ];
  }

  Widget _tagFilterTile(
    _TagRow t,
    void Function(void Function()) apply, {
    bool indented = false,
  }) =>
      CheckboxListTile(
        key: ValueKey('map_filter_tag_${t.tagId}'),
        dense: true,
        contentPadding: EdgeInsets.only(left: indented ? 44 : 20, right: 20),
        controlAffinity: ListTileControlAffinity.leading,
        value: !_hiddenTagIds.contains(t.tagId),
        onChanged: (v) => apply(() {
          if (v ?? false) {
            _hiddenTagIds.remove(t.tagId);
          } else {
            _hiddenTagIds.add(t.tagId);
            _selection = null;
          }
        }),
        title: Text('${t.frequencyMhz.toStringAsFixed(3)} MHz · ${t.tagName}',
            style: const TextStyle(fontSize: 13)),
      );

  /// The colour to draw an element from [tagId] recorded at [at] in — the
  /// animal whose deployment covers this exact moment (task 11.248's
  /// follow-up to 11.247: the same per-ray question, asked of colour as
  /// well as visibility), never whichever animal currently owns the
  /// collar.
  ///
  /// **A tag moved to a new animal must not repaint an earlier bearing in
  /// the new animal's colour.** Every element used to draw in the tag's
  /// *current* colour — right for equipment that has never changed hands,
  /// wrong the moment it does. Michael moved a collar from one animal to
  /// another and watched an old bearing, recorded while it was on the
  /// first, repaint in the second's colour — on the very map he was using
  /// to confirm task 11.247's filtering fix worked.
  ///
  /// [fallback] is used only for a tag id this project no longer holds (a
  /// dangling reference, e.g. a shared observation from a collar since
  /// removed) — a live tag with no covering deployment at [at] draws
  /// [TagColorPalette.noIndividual], the same neutral swatch a collar on
  /// nobody draws everywhere else. **So does a contested moment** (design
  /// §4a, task 11.251): two deployments cover it and neither animal's colour
  /// would be honest, so it draws in nobody's and the legend says why.
  Color _tagColor(
    String? tagId,
    DateTime at,
    Map<String, _TagRow> tagNames,
    List<_AnimalRow> individuals,
    List<Deployment> deployments,
    Color fallback,
  ) {
    if (tagId == null || !tagNames.containsKey(tagId)) return fallback;
    final animalId = DeploymentRepository.animalForObservationIn(
      deployments,
      tagId: tagId,
      at: at,
    ).sole;
    if (animalId != null) {
      for (final a in individuals) {
        if (a.individualId == animalId) return tagColorFromHex(a.colorHex);
      }
    }
    return tagColorFromHex(TagColorPalette.noIndividual);
  }

  /// Whether the viewshed overlay is actually being drawn right now — shared
  /// by the `OverlayImageLayer`'s own `if` and the tag-keyed legend, so the
  /// legend's "Viewshed" row can never show when there's nothing to show it
  /// for (or vice versa).
  bool _viewshedIsRendered() =>
      _showViewshed &&
      _viewshedPng != null &&
      _viewshedResult != null &&
      _isValidLatLngBoundsInput(
        _viewshedResult!.grid.north,
        _viewshedResult!.grid.south,
        _viewshedResult!.grid.west,
        _viewshedResult!.grid.east,
      );

  /// **The animal (or, on nobody, the collar) a visible element at [at]
  /// belongs to, and its colour** — task 11.248's follow-up to 11.247: the
  /// legend now asks the same per-moment question [_tagColor] does, so a
  /// legend row and the rays it names always agree. Reused by
  /// [_legendRows], which asks it once per visible element.
  ///
  /// **A contested moment gets a row of its own** (design §4a, task 11.251):
  /// the neutral swatch [_tagColor] draws it in, labelled with the word and
  /// the candidates — *"Contested: Kea or Marie"* — because a grey ray with
  /// no sentence beside it reads as "collar on nobody", which is a different
  /// fact. Colour never carries a meaning on its own in this app; here it
  /// carries the absence of one, and the label says so.
  (String, Color) _attributionOf(
    String tagId,
    DateTime at,
    Map<String, _TagRow> tagNames,
    List<_AnimalRow> individuals,
    List<Deployment> deployments,
  ) {
    final attribution = DeploymentRepository.animalForObservationIn(
      deployments,
      tagId: tagId,
      at: at,
    );
    String? nameOf(String animalId) {
      for (final a in individuals) {
        if (a.individualId == animalId) return a.name;
      }
      return null;
    }

    final sole = attribution.sole;
    if (sole != null) {
      for (final a in individuals) {
        if (a.individualId == sole) return (a.name, tagColorFromHex(a.colorHex));
      }
    }
    if (attribution.isContested) {
      // `nameOf` returns null for a candidate whose animal was deleted
      // since the deployment was recorded (task 11.258) — the raw id is not
      // a name to show anybody, so name the state instead.
      final names = [
        for (final id in attribution.candidates) nameOf(id) ?? 'a deleted animal',
      ]..sort();
      return (
        contestedLegendLabel(names),
        tagColorFromHex(TagColorPalette.noIndividual),
      );
    }
    final tag = tagNames[tagId];
    return (
      tag?.tagName ?? tagId,
      tagColorFromHex(TagColorPalette.noIndividual),
    );
  }

  /// Legend rows (Phase 4): (swatch color, name) for every animal — or
  /// collar, on nobody — with something currently rendered — respecting
  /// the layer toggles, the per-tag visibility filter, and the active
  /// time window — plus one fixed row for the viewshed overlay when it's
  /// actually on screen. Never lists every tag in the project, only ones
  /// with visible elements right now.
  List<(Color, String)> _legendRows(_MapData data, Map<String, _TagRow> tagNames) {
    // Task 11.248: keyed on the animal each *element* was actually about,
    // asked per element with its own timestamp — the same question
    // [_tagColor] answers for the ray itself — rather than on the
    // collar's current owner. Two collars re-collared onto one animal
    // still draw one row in her colour; a bearing recorded before a
    // reassignment keeps naming who it was really about, matching the ray
    // it labels rather than the equipment's current owner.
    final labeled = <String, Color>{};
    if (_showRays || _showWedges) {
      for (final o in data.observations) {
        if (o.trueNorthBearing != null &&
            o.tagId != null &&
            _visible(o.tagId, o.timestampUtc, data.deployments) &&
            _inTimeWindow(o.timestampUtc)) {
          final (label, color) = _attributionOf(
            o.tagId!,
            o.timestampUtc,
            tagNames,
            data.individuals,
            data.deployments,
          );
          labeled[label] = color;
        }
      }
    }
    if (_showEstimates) {
      for (final e in data.estimates) {
        if (_visible(e.tagId, e.timestampLocal, data.deployments) &&
            _inTimeWindow(e.timestampLocal)) {
          final (label, color) = _attributionOf(
            e.tagId,
            e.timestampLocal,
            tagNames,
            data.individuals,
            data.deployments,
          );
          labeled[label] = color;
        }
      }
    }
    if (_showTagLocations) {
      for (final t in data.tagLocations) {
        if (_visible(t.tagId, t.timestampUtc, data.deployments) &&
            _inTimeWindow(t.timestampUtc)) {
          final (label, color) = _attributionOf(
            t.tagId,
            t.timestampUtc,
            tagNames,
            data.individuals,
            data.deployments,
          );
          labeled[label] = color;
        }
      }
    }

    final tagRows = [
      for (final entry in labeled.entries) (entry.value, entry.key),
    ]..sort((a, b) => a.$2.compareTo(b.$2));

    return [
      ...tagRows,
      if (_viewshedIsRendered())
        (
          Theme.of(context).extension<TriTrackColors>()!.viewshedOverlay,
          // Task 11.142. The legend is the one label that is on the map for
          // exactly as long as the overlay is, so it is where the shape of
          // the claim belongs. Kept to two words because a legend row is a
          // single unwrapped line; the sentence is in the layers sheet.
          _viewshedResult!.terrainIsIncomplete
              ? 'Viewshed (partial terrain)'
              : 'Viewshed',
        ),
    ];
  }

  /// Inclusive [start, end) bounds for the active time window, or null for
  /// "all time". Computed from local "now"; day-aligned.
  ({DateTime start, DateTime end})? _timeBounds() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_timeWindow) {
      case _MapTimeWindow.all:
        return null;
      case _MapTimeWindow.today:
        return (start: today, end: today.add(const Duration(days: 1)));
      case _MapTimeWindow.yesterday:
        return (start: today.subtract(const Duration(days: 1)), end: today);
      case _MapTimeWindow.last7:
        return (start: today.subtract(const Duration(days: 6)), end: today.add(const Duration(days: 1)));
      case _MapTimeWindow.custom:
        final r = _customRange;
        if (r == null) return null;
        return (
          start: DateTime(r.start.year, r.start.month, r.start.day),
          end: DateTime(r.end.year, r.end.month, r.end.day).add(const Duration(days: 1)),
        );
    }
  }

  /// Whether a recording's timestamp falls in the active window. Bounds are
  /// local; timestamps are UTC, so compare in local time.
  bool _inTimeWindow(DateTime timestampUtc) {
    final bounds = _timeBounds();
    if (bounds == null) return true;
    final local = timestampUtc.toLocal();
    return !local.isBefore(bounds.start) && local.isBefore(bounds.end);
  }

  @override
  Widget build(BuildContext context) {
    final projectAsync = ref.watch(currentProjectProvider);
    return Scaffold(
      body: SafeArea(
        child: projectAsync.when(
          data: (project) => project == null
              ? const _NoProjectEmptyState()
              : _buildBody(context, project),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => LoadFailure('this project', error: e),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, Project project) {
    final currentUserAsync = ref.watch(currentUserProvider);
    final currentUser = currentUserAsync.value;
    // Task 11.12: whether the role gradient (not just authorship) permits
    // editing here — see `authorEditVerdict`. Defaults to not-permitted while
    // unresolved rather than gating the whole map behind a spinner: the Edit
    // affordance is secondary chrome on a screen whose primary purpose is
    // reading the map, unlike a settings form where the control being gated
    // is the screen's whole point.
    //
    // The standing rather than the bare bool since task 11.237, because the
    // sentence under a refused Edit depends on *why*: a viewer's, or a
    // snapshot's. "Not permitted while unresolved" is spelled as the viewer
    // standing, which is what `?? false` always meant here.
    final standing =
        ref.watch(myProjectStandingProvider(project.projectId)).value ??
        const ProjectStanding.member(ProjectRole.viewer);
    final gpsAsync = ref.watch(gpsPositionProvider);
    final dataAsync = ref.watch(_mapDataProvider(project.projectId));
    final tileCategoryAsync = ref.watch(selectedTileCategoryProvider);
    final tileSourceAsync = ref.watch(selectedTileSourceProvider);
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    // Task 11.332 item 6: one measurement per build, shared by every point
    // marker below, because each marker's box is sized from it.
    final markerLabelHeight = _MarkerLabel.heightIn(context);
    final status = ref.watch(computationStatusProvider);
    final shared = ref.watch(sharedObservationPreviewProvider);
    final navTarget = ref.watch(navigationTargetProvider).value;
    // The navigation panel's title. Built here rather than inline in the
    // widget tree: a free point has no name and falls back to its
    // coordinates, and that is two nested interpolations deep in a Row if it
    // is written where it is used.
    final navLabel = navTarget == null
        ? null
        : navTarget.label ??
            '${navTarget.latitude.toStringAsFixed(5)}, '
                '${navTarget.longitude.toStringAsFixed(5)}';
    final gps = gpsAsync.value;

    _maybeAutoComputeViewshed(project, gps);
    _maybeRecenterOnShared(shared);

    // Live viewshed: recompute from each new GPS fix once the user has moved
    // far enough (150 m) from the last computed observer, so the overlay
    // follows them as they drive without thrashing on every 5 m stream tick.
    ref.listen(gpsPositionProvider, (prev, next) {
      if (!_liveViewshed || _viewshedBusy) return;
      final p = next.value;
      if (p == null) return;
      final here = ll.LatLng(p.latitude, p.longitude);
      final last = _viewshedObserver;
      if (last != null &&
          const ll.Distance().as(ll.LengthUnit.Meter, last, here) < 150) {
        return;
      }
      _computeViewshedAt(
        p.latitude,
        p.longitude,
        autoEnableLayer: true,
        silentIfNoCoverage: true,
      );
    });

    return dataAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => LoadFailure(
        'the bearings and estimates for this project',
        error: e,
      ),
      data: (data) {
        final tileSource = tileSourceAsync.value ?? TileSources.openStreetMap;
        final tagNames = {for (final t in data.tags) t.tagId: t};
        final legendRows = _legendRows(data, tagNames);
        final cameraTarget = _cameraTarget(project, gps, data);
        // Task 11.103: null exactly when nothing was supplied. The world
        // view is a framing, not a claim — see `MapCameraTarget`.
        final initialCenter =
            cameraTarget.center ?? MapCameraTarget.worldViewCenter;
        final initialZoom = cameraTarget.zoom;

        // Selection-driven highlighting: when an estimate is selected,
        // the bearings that produced it (or, when a bearing is selected,
        // that bearing) are drawn full-strength and the rest dimmed.
        final selection = _selection;
        final highlightIds = switch (selection) {
          _EstSelection(:final estimate) => estimate.highlightableObservationIds,
          _ObsSelection(:final observation) => {observation.observationId},
          _ => <String>{},
        };
        final hasHighlight = highlightIds.isNotEmpty;

        // Error ellipse for a selected estimate (its own show/hide).
        final selectedEstimate = selection is _EstSelection
            ? selection.estimate
            : null;
        final selectedEstimateColor = selectedEstimate == null
            ? colors.estimatedPosition
            : _tagColor(
                selectedEstimate.tagId,
                selectedEstimate.timestampLocal,
                tagNames,
                data.individuals,
                data.deployments,
                colors.estimatedPosition,
              );
        final ellipsePolygon =
            (selectedEstimate != null &&
                _showSelectedEllipse &&
                selectedEstimate.hasEllipse)
            ? [
                for (final p in ellipsePolygonPoints(
                  center: GeoPoint(
                    selectedEstimate.latitude,
                    selectedEstimate.longitude,
                  ),
                  semiMajorMeters: selectedEstimate.semiMajorAxis!,
                  semiMinorMeters: selectedEstimate.semiMinorAxis!,
                  rotationCompassDeg: selectedEstimate.rotationAngle ?? 0,
                ))
                  ll.LatLng(p.latitude, p.longitude),
              ]
            : null;
        if (!_cameraSeeded) {
          _cameraSeeded = true;
          _cameraCenter = initialCenter;
          _cameraZoom = initialZoom;
        }

        // Task 11.126 item B: everything anchored to the bottom edge is laid
        // out against measured heights, so re-read them after this frame.
        _rememberBottomGeometry();

        return Stack(
          key: const ValueKey('main-map'),
          children: [
            DesktopTrackpadZoom(
              mapController: _mapController,
              child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: initialCenter,
                initialZoom: initialZoom,
                // Fit the rectangle when the chain produced one (a project
                // extent, or a day's recordings spread over ground); a
                // fixed zoom on its centre otherwise.
                initialCameraFit: cameraTarget.extent == null
                    ? null
                    : CameraFit.bounds(
                        bounds: LatLngBounds(
                          ll.LatLng(cameraTarget.extent!.minLat,
                              cameraTarget.extent!.minLon),
                          ll.LatLng(cameraTarget.extent!.maxLat,
                              cameraTarget.extent!.maxLon),
                        ),
                        padding: const EdgeInsets.all(40),
                        maxZoom: 16,
                      ),
                minZoom: 2,
                // Web Mercator's latitude is only defined up to
                // ~85.0511°; letting the camera pan/zoom past that
                // (or the raw ±90° poles) feeds NaN/Infinity into
                // downstream lat/lon math (scale bar, viewshed
                // bounds, measure tool) which then blows up layout
                // as NaN BoxConstraints and runaway tile allocation.
                cameraConstraint: const CameraConstraint.containLatitude(
                  85.05112878,
                  -85.05112878,
                ),
                onTap: (_, point) => _onMapTap(project, point, data),
                onLongPress: (_, point) => _onMapLongPress(point),
                initialRotation: 0,
                // Default flutter_map behavior applies pan/zoom/rotate
                // simultaneously with no threshold, so any slight twist
                // while pinching or panning immediately rotates the
                // map — reported as "too sensitive, hard to pan/zoom
                // without rotating." Racing the gestures with a raised
                // rotation threshold means a deliberate two-finger
                // twist is needed before rotation wins over pan/zoom.
                interactionOptions: InteractionOptions(
                  flags: mapInteractionFlags(),
                  enableMultiFingerGestureRace: true,
                  rotationThreshold: 30.0,
                  pinchZoomThreshold: 0.5,
                  pinchMoveThreshold: 40.0,
                ),
                // The scale bar and north arrow depend on the live
                // zoom/rotation, which flutter_map doesn't expose as a
                // listenable on its own — mirror the camera into state
                // on every pan/zoom/rotate so they track it and force
                // the rebuild needed to repaint them.
                onMapEvent: (event) => setState(() {
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
                // Task 11.87 tried a vector-drawn boundary, then a
                // vector-filled polygon — a real device reported the vector
                // fill as "extremely laggy," so this is a flat raster PNG
                // fill again: baked once, then GPU-sampled like any other
                // texture. See renderViewshedPng's doc comment.
                if (_viewshedIsRendered())
                  OverlayImageLayer(
                    overlayImages: [
                      OverlayImage(
                        bounds: LatLngBounds(
                          ll.LatLng(
                            _viewshedResult!.grid.north,
                            _viewshedResult!.grid.west,
                          ),
                          ll.LatLng(
                            _viewshedResult!.grid.south,
                            _viewshedResult!.grid.east,
                          ),
                        ),
                        imageProvider: MemoryImage(_viewshedPng!),
                        opacity: _viewshedOpacity,
                        // The overlay is baked at grid (~90 m cell)
                        // resolution; nearest-neighbour keeps its edge
                        // crisp when zoomed in instead of the default
                        // bilinear smoothing blurring it.
                        filterQuality: FilterQuality.none,
                      ),
                    ],
                  ),
                if (ellipsePolygon != null)
                  PolygonLayer(
                    polygons: [
                      Polygon(
                        points: ellipsePolygon,
                        color: selectedEstimateColor.withValues(alpha: 0.18),
                        borderColor: selectedEstimateColor.withValues(
                          alpha: 0.7,
                        ),
                        borderStrokeWidth: 1.5,
                      ),
                    ],
                  ),
                // Uncertainty wedges, drawn under the rays so the ray lines
                // and origin circles stay crisp on top. Each fans
                // ±bearingUncertainty° from the measurement point out to
                // `_bearingRangeMeters(o)` — the *same* call the ray below
                // makes, so the two cannot disagree about how far a bearing
                // reaches (task 11.131; they were two separate `400`
                // literals). You can see both where it was measured and how
                // tight the bearing was. Independent "Uncertainty wedges"
                // layer toggle (default on) — not tied to _showRays, per
                // user feedback that it should be its own layer like
                // bearings/estimates/tag locations.
                //
                // Task 11.185: when a selected estimate's ellipse is actually
                // drawn, the wedges of the bearings that produced it sit on
                // top of the ellipse at a heavier alpha than the ellipse
                // itself, burying it. Those wedges (and only those — other
                // wedges stay as they are) are skipped while the ellipse is
                // shown; the ray highlight already answers which bearings
                // made it. Keyed on `ellipsePolygon != null`, not on
                // "an estimate is selected" — an estimate whose ellipse can't
                // be drawn keeps its wedges.
                if (_showWedges)
                  PolygonLayer(
                    polygons: [
                      for (final o in data.observations)
                        if (o.trueNorthBearing != null &&
                            _visible(o.tagId, o.timestampUtc, data.deployments) &&
                            _inTimeWindow(o.timestampUtc) &&
                            !(ellipsePolygon != null &&
                                highlightIds.contains(o.observationId)))
                        () {
                          final used = highlightIds.contains(o.observationId);
                          final dimmed = hasHighlight && !used;
                          final half =
                              (o.bearingUncertainty ?? 12.0).clamp(0.0, 90.0);
                          final rayColor = _tagColor(
                            o.tagId,
                            o.timestampUtc,
                            tagNames,
                            data.individuals,
                            data.deployments,
                            colors.bearingRay,
                          );
                          return Polygon(
                            // Memoised: a tip drag is a setState per frame,
                            // and only the dragged bearing's inputs have
                            // changed, so only its wedge is recomputed.
                            points: _wedgeCache.points(
                              observationId: o.observationId,
                              latitude: o.latitude,
                              longitude: o.longitude,
                              bearingDeg: o.trueNorthBearing!,
                              halfWidthDeg: half.toDouble(),
                              rangeMeters:
                                  _bearingRangeMeters(o.observationId),
                            ),
                            color: rayColor.withValues(
                              alpha: dimmed ? 0.08 : (used ? 0.35 : 0.2),
                            ),
                            borderColor: rayColor.withValues(
                              alpha: dimmed ? 0.14 : 0.45,
                            ),
                            borderStrokeWidth: 0.5,
                          );
                        }(),
                    ],
                  ),
                if (_showRays)
                  PolylineLayer(
                    polylines: [
                      for (final o in data.observations)
                        if (o.trueNorthBearing != null &&
                            _visible(o.tagId, o.timestampUtc, data.deployments) &&
                            _inTimeWindow(o.timestampUtc))
                        () {
                          final used = highlightIds.contains(o.observationId);
                          final dimmed = hasHighlight && !used;
                          final rayColor = _tagColor(
                            o.tagId,
                            o.timestampUtc,
                            tagNames,
                            data.individuals,
                            data.deployments,
                            colors.bearingRay,
                          );
                          return Polyline(
                            points: [
                              ll.LatLng(o.latitude, o.longitude),
                              () {
                                final dest = destinationPoint(
                                  GeoPoint(o.latitude, o.longitude),
                                  o.trueNorthBearing!,
                                  _bearingRangeMeters(o.observationId),
                                );
                                return ll.LatLng(dest.latitude, dest.longitude);
                              }(),
                            ],
                            color: dimmed
                                ? rayColor.withValues(alpha: 0.25)
                                : rayColor,
                            strokeWidth: used ? 4 : 2,
                          );
                        }(),
                    ],
                  ),
                if (_measurePoints.length == 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _measurePoints,
                        color: Theme.of(context).colorScheme.onSurface,
                        strokeWidth: 2,
                        pattern: StrokePattern.dashed(
                          segments: const [8.0, 6.0],
                        ),
                      ),
                    ],
                  ),
                if (navTarget != null && gps != null)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: [
                          ll.LatLng(gps.latitude, gps.longitude),
                          ll.LatLng(navTarget.latitude, navTarget.longitude),
                        ],
                        color: colors.navigationLine,
                        strokeWidth: 3,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    if (navTarget != null)
                      Marker(
                        point: ll.LatLng(navTarget.latitude, navTarget.longitude),
                        width: 32,
                        height: 32,
                        // Task 11.102: `MapPinMarker`'s tip is guaranteed by
                        // construction to sit at the box's bottom-center, so
                        // `Alignment.bottomCenter` is exactly right here with
                        // no per-marker fraction to get wrong — see that
                        // widget's doc comment for why this replaced a bare
                        // `Icon(Icons.flag)` at `Alignment.topCenter`.
                        alignment: Alignment.bottomCenter,
                        child: MapPinMarker(color: colors.navigationLine),
                      ),
                    if (_showViewshed && _viewshedObserver != null)
                      Marker(
                        point: _viewshedObserver!,
                        width: 32,
                        height: 32,
                        child: _ViewshedObserverMarker(
                          color: colors.viewshedOverlay,
                        ),
                      ),
                    for (var i = 0; i < _measurePoints.length; i++)
                      Marker(
                        point: _measurePoints[i],
                        width: 28,
                        height: 28,
                        child: _MeasurePointHandle(
                          onDrag: (delta) => _dragMeasurePoint(i, delta),
                        ),
                      ),
                    if (gps != null)
                      Marker(
                        point: ll.LatLng(gps.latitude, gps.longitude),
                        width: 20,
                        height: 20,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                    // A circle at each bearing's measurement position, so it's
                    // clear which end of the ray the reading was taken from.
                    if (_showRays)
                      for (final o in data.observations)
                        if (o.trueNorthBearing != null &&
                            _visible(o.tagId, o.timestampUtc, data.deployments) &&
                            _inTimeWindow(o.timestampUtc))
                        Marker(
                          point: ll.LatLng(o.latitude, o.longitude),
                          width: 14,
                          height: 14,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: _tagColor(
                                o.tagId,
                                o.timestampUtc,
                                tagNames,
                                data.individuals,
                                data.deployments,
                                colors.bearingRay,
                              ).withValues(
                                alpha: hasHighlight &&
                                        !highlightIds.contains(o.observationId)
                                    ? 0.35
                                    : 1.0,
                              ),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ),
                    // Task 11.131: the grab handle at the selected
                    // bearing's tip. Nothing else on this screen tells anybody
                    // the length can be dragged, so the handle *is* the
                    // discoverability — it appears the moment a bearing is
                    // selected and nowhere else, and it is last in this layer
                    // so it sits above the origin dots and any ray crossing
                    // it.
                    if (_showRays && selection is _ObsSelection)
                      ...() {
                        final o = selection.observation;
                        if (o.trueNorthBearing == null ||
                            !_visible(o.tagId, o.timestampUtc, data.deployments) ||
                            !_inTimeWindow(o.timestampUtc)) {
                          return const <Marker>[];
                        }
                        final point = _tipHandlePoint(o);
                        if (point == null) return const <Marker>[];
                        return [
                          Marker(
                            key: const ValueKey('bearing-tip-handle'),
                            point: point,
                            // 44 logical pixels of touch target around a much
                            // smaller drawn dot — the minimum comfortable
                            // target, not the size of the thing you see.
                            width: 44,
                            height: 44,
                            child: _BearingTipHandle(
                              color: _tagColor(
                                o.tagId,
                                o.timestampUtc,
                                tagNames,
                                data.individuals,
                                data.deployments,
                                colors.bearingRay,
                              ),
                              dragging:
                                  _tipDragObservationId == o.observationId,
                              onDragStart: () => _beginTipDrag(o),
                              onDragUpdate: (offset) =>
                                  _updateTipDrag(o, offset),
                              onDragEnd: _endTipDrag,
                              onReset: () =>
                                  _resetBearingLength(o.observationId),
                            ),
                          ),
                        ];
                      }(),
                    if (_showEstimates)
                      for (final e in data.estimates)
                        if (_visible(e.tagId, e.timestampLocal, data.deployments) &&
                            _inTimeWindow(e.timestampLocal))
                        Marker(
                          point: ll.LatLng(e.latitude, e.longitude),
                          width: _markerLabelWidth,
                          height: _pointMarkerHeight(
                            _EstimateMarker.glyphSize,
                            markerLabelHeight,
                          ),
                          // Anchor the 18px dot (top of the column) on the
                          // point so it stays co-centered with the error
                          // ellipse; the label hangs below. (Plain topCenter
                          // would put the point at the box's bottom, floating
                          // the dot above it.)
                          alignment: _pointMarkerAlignment(
                            _EstimateMarker.glyphSize,
                            markerLabelHeight,
                          ),
                          child: _EstimateMarker(
                            color: _tagColor(
                              e.tagId,
                              e.timestampLocal,
                              tagNames,
                              data.individuals,
                              data.deployments,
                              colors.estimatedPosition,
                            ),
                            label: _markerLabel('Estimate', tagNames[e.tagId]),
                          ),
                        ),
                    if (_showTagLocations)
                      for (final t in data.tagLocations)
                        if (_visible(t.tagId, t.timestampUtc, data.deployments) &&
                            _inTimeWindow(t.timestampUtc))
                        Marker(
                          point: ll.LatLng(t.latitude, t.longitude),
                          width: _markerLabelWidth,
                          height: _pointMarkerHeight(
                            _TagLocationMarker.glyphSize,
                            markerLabelHeight,
                          ),
                          // Task 11.100: anchor the 16px square (top of the
                          // column) on the point, so the marker is drawn
                          // where the truth point actually is and a tap on it
                          // falls inside `_selectAtPoint`'s 24px radius.
                          // Plain topCenter put the box's *bottom* on the
                          // point, floating the square ~28px above it — about
                          // 100m of apparent ground offset at survey zoom.
                          alignment: _pointMarkerAlignment(
                            _TagLocationMarker.glyphSize,
                            markerLabelHeight,
                          ),
                          child: _TagLocationMarker(
                            color: _tagColor(
                              t.tagId,
                              t.timestampUtc,
                              tagNames,
                              data.individuals,
                              data.deployments,
                              colors.animalFix,
                            ),
                            label: _markerLabel('Truth', tagNames[t.tagId]),
                          ),
                        ),
                    if (_showNonDetections)
                      for (final nd in data.nonDetections)
                        if (nd.tagIds.any(
                              (id) => _visible(id, nd.timestampUtc, data.deployments),
                            ) &&
                            _inTimeWindow(nd.timestampUtc))
                        Marker(
                          point: ll.LatLng(nd.latitude, nd.longitude),
                          width: 22,
                          height: 22,
                          // Task 11.94/11.101 exemption: the tag count is
                          // only in `tooltip:`, but the marker's own
                          // `volume_off` glyph already says "no signal"
                          // visually — the tooltip adds a count, it is not
                          // the marker's only label. Not a control (no
                          // `onTap`), just a status glyph.
                          child: Tooltip(
                            message: 'No signal · ${nd.tagIds.length} '
                                '${nd.tagIds.length == 1 ? 'tag' : 'tags'}',
                            // **Task 11.200: `onSurface`, deliberately, and it
                            // is not a copy-paste of the muted colour beside
                            // it.** This glyph is a map marker drawn over
                            // imagery, not a secondary label on a card; it was
                            // written as `onSurfaceVariant` while that token
                            // resolved to `onSurface`, so it has always been
                            // full-strength and this line keeps it that way.
                            // On the 0.9-alpha disc it sits on, the muted grey
                            // measures 4.69:1 against 15.25:1 for full
                            // strength — fine for a word on a card, thin for a
                            // 13-pixel glyph read at arm's length in sun.
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.onSurface,
                                  width: 1.5,
                                ),
                              ),
                              child: Icon(
                                Icons.volume_off,
                                size: 13,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                    if (shared != null)
                      Marker(
                        point: ll.LatLng(shared.latitude, shared.longitude),
                        width: 140,
                        height: _pointMarkerHeight(
                          _SharedObservationMarker.glyphSize,
                          markerLabelHeight,
                        ),
                        // Task 11.100: same anchor defect as the truth-point
                        // marker above — the 18px ring is the top of the
                        // column, so its center is what sits on the point.
                        alignment: _pointMarkerAlignment(
                          _SharedObservationMarker.glyphSize,
                          markerLabelHeight,
                        ),
                        child: _SharedObservationMarker(
                          label: '${shared.tagName} · shared',
                        ),
                      ),
                  ],
                ),
              ],
              ),
            ),
            if (!_centeredOnce && gps != null) _recenterOnce(gps),
            // **One left-hand column, not two things at the same
            // coordinates** (task 11.110). The north arrow and the
            // navigation banner were both `left: 12, top: 56`, and the
            // banner is painted later, so starting navigation on a rotated
            // map hid the only control that puts it back north-up. They
            // became two conditions stacked in this one column, and task
            // 11.207 then moved navigation out of it altogether — it is a
            // panel on the bottom edge now. See this file's SPACE BUDGET.
            Positioned(
              key: const ValueKey('map-left-band'),
              left: 12,
              // Below the floating tile-selector at the top.
              top: 56,
              right: 76,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Task 11.103. The map is showing the whole planet because
                  // nothing supplied a place: no fix, nothing recorded, no
                  // project extent. Saying so is the honest rendering of "I
                  // do not know where you are"; centring on 0,0 at street
                  // zoom, which is what this did before, was not.
                  //
                  // It stacks in the existing left column rather than adding
                  // an overlay of its own (task 11.110's rule), and it is
                  // gone the moment any one of the three arrives — so it
                  // costs the screen nothing on any day after the first.
                  if (!cameraTarget.isSupplied) ...[
                    const MapNoticeBanner(
                      message: MapCameraTarget.nothingSuppliedMessage,
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Task 11.134. Tiles have stopped arriving — a block, a
                  // rate limit, a dead network or a provider outage, and the
                  // fetch cannot tell which, so the message does not claim
                  // to. Before this, all four were a blank basemap with no
                  // sentence, which is indistinguishable from a basemap with
                  // nothing to draw.
                  //
                  // It stacks in this existing column (rule 4) rather than
                  // taking an anchor, and it is conditional: it costs the
                  // screen nothing while tiles are arriving or while the
                  // region is fully cached, because a cache hit is not
                  // reported as either outcome.
                  //
                  // Task 11.135 moved the widget itself into
                  // `map_furniture.dart` — four more maps now show the same
                  // sentence, and one shape at five call sites is one shape
                  // that drifts at five call sites. Nothing here changes: the
                  // key, the words and the sheet behind them are the same.
                  const TilesNotLoadingBand(
                    bannerKey: ValueKey('map-tiles-not-loading'),
                    padding: EdgeInsets.only(bottom: 8),
                  ),
                  // A north arrow on a north-up map is not information, and
                  // this one's only job is to put the map back — so it
                  // appears when there is something to put back.
                  if (_cameraRotation.abs() > 0.5) ...[
                    MapNorthArrow(
                      rotationDeg: _cameraRotation,
                      onTap: () => _mapController.rotate(0),
                    ),
                    const SizedBox(height: 8),
                  ],
                  // **The navigation banner used to be here** and is now
                  // the bottom panel below (task 11.207): the same target,
                  // distance, bearing and Stop, in a bar that pulls up into
                  // the terrain profile between here and there. One widget
                  // draws both this and the measure tool's profile, so the
                  // climb number cannot be right in one of them and wrong in
                  // the other.
                ],
              ),
            ),
            // Task 11.95: the map-source credit is now the bottom of this
            // one column rather than a separately positioned bar sitting
            // under it, so the scale bar and lat/lon readout clear it by
            // construction however many lines the credit wraps to, instead
            // of by a `bottom:` constant chosen for a one-line credit.
            Positioned(
              key: const ValueKey('map-bottom-band'),
              left: 12,
              // Clear of the "+" FAB in the bottom-right. This is also what
              // decides where the credit wraps, so it must not be widened
              // without rechecking the credit on a phone.
              right: 76,
              // Task 11.126 item B: lifted by whatever transient panel is up,
              // because the selection card covered this band whole — scale
              // bar, coordinates and the map-source credit, which is a
              // licence condition and not decoration.
              bottom: 8 + _bottomFurnitureLift(),
              // **Nothing in this band is a control** — a scale bar, a
              // coordinate readout and a credit line — and once it is lifted
              // above a selection card it sits where task 11.131's bearing
              // grab handle can be clamped to. An output-only band that eats
              // the grab would make a dragged-out bearing unretractable by
              // the direct route, so it lets the pointer through. It also
              // means a pan that starts on the scale bar pans the map.
              // Task 11.133 item 2: the `IgnorePointer` now covers the scale
              // bar and the coordinate readout — which are output and nothing
              // else — while `MapAttribution` manages its own, because the
              // credit's "ⓘ" is a control and a control cannot live inside
              // one. See that widget for what it does and does not let
              // through.
              child: Column(
                key: _bottomBandKey,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  IgnorePointer(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MapScaleBar(
                          latitude: _cameraCenter.latitude,
                          zoom: _cameraZoom,
                        ),
                        const SizedBox(height: 6),
                        CoordinateReadout(
                          gps: gps,
                          format: project.coordinateFormat,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  MapAttribution(
                    source: tileSource,
                    onShowDetails: () =>
                        showMapAttributionSheet(context, tileSource),
                  ),
                ],
              ),
            ),
            if (_showLegend && legendRows.isNotEmpty)
              Positioned(
                right: 12,
                // Above the "+" column (bottom-right) so they don't overlap,
                // and above the transient bottom column when one is up —
                // both by their measured heights, not by a constant (task
                // 11.126).
                //
                // **Task 11.189 made the first of those a measurement too.**
                // It was the constant 84 — the "+" button's 56 plus its 20
                // inset plus an 8-pixel gap — written down here while the
                // widget it describes lives forty lines below, which is the
                // shape this project keeps being bitten by. The sync status
                // icon then joined that column *conditionally*, so no
                // constant could have been right in both states.
                // `_recordFabHeight` was already being measured and read by
                // nothing at all.
                bottom: _bottomRightColumnTop() + _bottomFurnitureLift(),
                child: MapLegendCard(
                  rows: legendRows,
                  // Task 11.206: this used to be a permanent italic note on
                  // the selection card, in breach of this file's SPACE
                  // BUDGET rule 5 ("onboarding copy never occupies permanent
                  // space") — it appeared every time an estimate with an
                  // ellipse was selected, which is the ordinary case. Moved
                  // here, behind the control people already press to ask
                  // what they are looking at.
                  footnote: ellipsePolygon != null
                      ? 'Bearing wedges are hidden while an estimate\'s '
                          'ellipse is shown; the heavy lines show which '
                          'bearings made it.'
                      : null,
                ),
              ),
            // Top-center: the shared-preview banner when active,
            // otherwise the floating map-type selector (translucent, so
            // the map shows through and fills the full height). Both are
            // inset from the screen edges.
            if (shared != null)
              Positioned(
                key: const ValueKey('map-top-band'),
                left: 12,
                right: 12,
                top: 8,
                child: _SharedObservationBanner(
                  tagName: shared.tagName,
                  onClear: () => ref
                      .read(sharedObservationPreviewProvider.notifier)
                      .clear(),
                ),
              )
            else
              Positioned(
                key: const ValueKey('map-top-band'),
                top: 8,
                left: 12,
                right: 12,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    // `MapTypeToggle` (`map_furniture.dart`) is the halo
                    // control task 11.190 built here; task 11.317 pulled it
                    // out so *Take on map* shares it rather than building a
                    // second one.
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
              ),
            Positioned(
              key: const ValueKey('map-right-controls'),
              right: 12,
              top: 56,
              child: Column(
                children: [
                  _LayersFiltersButton(
                    active: _hiddenTagIds.isNotEmpty ||
                        _hiddenAnimalIds.isNotEmpty ||
                        _timeWindow != _MapTimeWindow.all,
                    onPressed: () => _showLayersFiltersSheet(context, data),
                  ),
                  const SizedBox(height: 8),
                  MeasureButton(
                    active: _measureMode,
                    onPressed: () => setState(() {
                      _measureMode = !_measureMode;
                      if (_measureMode) _selection = null;
                      if (!_measureMode) _measurePoints.clear();
                    }),
                  ),
                  const SizedBox(height: 8),
                  _MyLocationButton(onPressed: () => _centerOnMyLocation(gps)),
                ],
              ),
            ),
            Positioned(
              key: const ValueKey('map-record-fab'),
              right: 20,
              // Rides above the transient bottom column, the way a floating
              // action button rides above a bottom sheet (task 11.126 item
              // B). The selection card used to cover it whole.
              bottom: 20 + _bottomFurnitureLift(),
              child: Column(
                key: _recordFabKey,
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // **Task 11.189: the sync status, right above the "+",
                  // which is where Michael asked for it.** It replaced a
                  // coloured strip across the top of every tab; see
                  // `SyncStatusIcon` for what that cost and for task 10.2's
                  // invariant that this renders nothing at all when no server
                  // is configured.
                  //
                  // It is one anchor with the "+" rather than a `Positioned`
                  // of its own — rule 4 of this file's SPACE BUDGET, and the
                  // reason the legend below can clear both of them by a
                  // measured height instead of a constant.
                  const SyncStatusIcon(padding: EdgeInsets.only(bottom: 8)),
                  FloatingActionButton(
                    // Its own hero tag: every tab's "+" is built at once,
                    // and a shared default tag fails *Take on map*'s push
                    // in a debug build (task 11.323).
                    heroTag: 'fab-map-record',
                    onPressed: () => context.go('/record'),
                    child: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
            // **One transient bottom column, not four anchors** (task 11.126
            // item B; rule 4 of this file's SPACE BUDGET). The selection
            // card, the measure readout, the elevation profile and the
            // computation progress bar were four separate `Positioned`
            // children on the bottom edge — three of them at `bottom: 0` or
            // `bottom: 12` — with conditions that are not mutually
            // exclusive. A `Stack` says nothing when two children overlap:
            // the later one simply paints over the earlier. Measured at
            // phone geometry the selection card covered the "+" record
            // button whole, together with the scale bar, the coordinate
            // readout and the map-source credit, and the progress bar
            // covered the bottom of the elevation profile.
            //
            // They stack now, in one column that keeps the bottom edge, and
            // the two permanent things on that edge — the readout band and
            // the "+" — are lifted above it by **this column's measured
            // height** rather than by a constant. Same mechanism as task
            // 11.131's drag handle, and see [_bottomFurnitureLift] for why
            // the furniture moves rather than the panels.
            if (selection != null ||
                _measurePoints.isNotEmpty ||
                navTarget != null ||
                status is ComputationRunning ||
                status is ComputationFailed)
              Positioned(
                key: const ValueKey('map-bottom-panels'),
                left: 12,
                right: 12,
                bottom: 12,
                child: Column(
                  key: _bottomPanelsKey,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (status is ComputationRunning) ...[
                      _ComputationProgressBar(
                        key: const ValueKey('map-computation-progress'),
                        status: status,
                      ),
                      const SizedBox(height: 8),
                    ],
                    // Task 11.87. Before this, a failed computation cleared
                    // `ComputationRunning`'s progress bar and the message
                    // written into `ComputationFailed` was never displayed
                    // anywhere — the bar just vanished and told nobody
                    // anything.
                    if (status is ComputationFailed) ...[
                      _ComputationFailedBar(
                        key: const ValueKey('map-computation-failed'),
                        status: status,
                        onDismiss: () => ref
                            .read(computationStatusProvider.notifier)
                            .reset(),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_measurePoints.length == 1) ...[
                      Center(
                        child: MeasureResultCard(
                          points: _measurePoints,
                          onClear: () => setState(_measurePoints.clear),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_measurePoints.length == 2) ...[
                      ElevationProfilePanel(
                        key: const ValueKey('map-elevation-panel'),
                        origin: _measurePoints[0],
                        destination: _measurePoints[1],
                        icon: Icons.straighten,
                        // The dashed line this is a profile of, above.
                        lineColor: Theme.of(context).colorScheme.onSurface,
                        action: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: 'Clear',
                          onPressed: () => setState(_measurePoints.clear),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    // **Task 11.207: this replaced the navigation banner.**
                    // Collapsed it is the same one line the banner was —
                    // target, distance, bearing, Stop — and it opens into the
                    // terrain between here and there, climb and descent
                    // included. It follows the person walking; what that does
                    // and deliberately does not do is in
                    // [ElevationProfilePanel]'s own doc, and the short version
                    // is that nothing here runs unless the app is in front of
                    // somebody.
                    if (navTarget != null) ...[
                      ElevationProfilePanel(
                        key: const ValueKey('map-navigation-panel'),
                        origin: null,
                        destination: ll.LatLng(
                          navTarget.latitude,
                          navTarget.longitude,
                        ),
                        icon: Icons.navigation,
                        // The navigation line this is a profile of, above.
                        lineColor: colors.navigationLine,
                        label: 'To $navLabel',
                        initiallyCollapsed: true,
                        action: TextButton(
                          onPressed: () =>
                              ref.read(navigationTargetProvider.notifier).stop(),
                          child: const Text('Stop'),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (selection != null)
                      _SelectionInfoPanel(
                        key: const ValueKey('map-selection-panel'),
                        selection: selection,
                        currentUserId: currentUser?.userId,
                        standing: standing,
                        tagNames: tagNames,
                        coordinateFormat: project.coordinateFormat,
                        showEllipse: _showSelectedEllipse,
                        onToggleEllipse: (v) =>
                            setState(() => _showSelectedEllipse = v),
                        onClose: () => setState(() => _selection = null),
                        onEditObservation: (o) async {
                          final updated = await showEditObservationDialog(
                            context,
                            ref,
                            o,
                          );
                          if (updated != null && mounted) {
                            setState(() => _selection = _ObsSelection(updated));
                          }
                        },
                        onEditEstimate: () => context.go('/position'),
                        // Task 11.92. The panel is re-seeded with the saved row
                        // rather than left showing the values the user just changed:
                        // `_mapDataProvider` refreshes off the revision bump, but the
                        // selection holds its own copy of the row and would otherwise
                        // keep displaying the old precision until the point was
                        // tapped again.
                        onEditTagLocation: (l) async {
                          final updated = await showEditTruthPointDialog(context, ref, l);
                          if (updated != null && mounted) {
                            setState(
                              () => _selection = _TagLocSelection(_TagLocationRow(updated)),
                            );
                          }
                        },
                        onDeleteTagLocation: (l) async {
                          final deleted = await confirmAndDeleteTruthPoint(context, ref, l);
                          // The panel is closed only on an actual delete — a
                          // cancelled confirm must leave the point selected, and an
                          // undo from the snackbar puts the point back on the map
                          // whether or not the panel was showing it.
                          if (deleted && mounted) setState(() => _selection = null);
                        },
                        onNavigate: _navigateTo,
                        onCopyForTriTrack: (o) => _copyForTriTrack(context, o),
                      ),
                  ],
                ),
              ),
            // Task 11.131: how long the bearing currently is, while it is
            // being dragged and only then.
            //
            // **This is what makes the gesture a measurement rather than a
            // fidget** — without it somebody is dragging a shape to a length
            // they cannot name. It costs the screen's space budget nothing,
            // because it exists only for the seconds a finger is on the
            // handle; it is placed under the map-type selector rather than
            // over it, and it may briefly overlap the left-hand banner
            // column, which is accepted for a readout the person is actively
            // producing.
            if (_tipDragObservationId != null)
              Positioned(
                key: const ValueKey('bearing-length-readout'),
                left: 0,
                right: 0,
                top: 50,
                child: Center(
                  child: _BearingLengthReadout(
                    rangeMeters:
                        _bearingRangeMeters(_tipDragObservationId!),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // Widgets can't imperatively move the map inside build(); scheduling the
  // move for the next frame (once) keeps this out of the widget tree cleanly.
  Widget _recenterOnce(Position gps) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _centeredOnce) return;
      _centeredOnce = true;
      _mapController.move(ll.LatLng(gps.latitude, gps.longitude), 15);
    });
    return const SizedBox.shrink();
  }

  /// Moves one measure-point handle by a screen-pixel [delta] (from the
  /// handle's own pan gesture): projects the point's current LatLng to a
  /// screen offset, applies the delta there, then unprojects back — so the
  /// drag tracks the finger correctly regardless of current zoom/rotation.
  void _dragMeasurePoint(int index, Offset delta) {
    final camera = _mapController.camera;
    final currentScreen = camera.latLngToScreenOffset(_measurePoints[index]);
    final newLatLng = camera.screenOffsetToLatLng(currentScreen + delta);
    // Near the poles / at extreme zoom this reprojection can go non-finite
    // or out of valid lat/lon range; drop the drag rather than storing a
    // bad point that later feeds a LatLng/Marker with NaN coordinates.
    if (!newLatLng.latitude.isFinite ||
        !newLatLng.longitude.isFinite ||
        newLatLng.latitude > 90.0 ||
        newLatLng.latitude < -90.0) {
      return;
    }
    setState(() => _measurePoints[index] = newLatLng);
  }

  /// Begins a tip drag on [o]'s bearing: remembers where the length started
  /// so every later frame is computed from the *total* offset since the press
  /// rather than by accumulating per-frame deltas, which drifts.
  void _beginTipDrag(Observation o) {
    setState(() {
      _tipDragObservationId = o.observationId;
      _tipDragStartRangeMeters = _bearingRangeMeters(o.observationId);
    });
  }

  /// Updates the dragged bearing's length from [totalOffset] — the screen
  /// offset accumulated since the press began.
  ///
  /// **Radial, by projection.** Only the component of the drag along the
  /// bearing direction counts, so dragging sideways does not lengthen the
  /// ray and the tip stays on the line it belongs to. The direction and the
  /// pixels-per-metre scale are both re-read from the live camera each frame,
  /// so a zoom or rotate mid-drag doesn't desynchronise the finger from the
  /// tip.
  void _updateTipDrag(Observation o, Offset totalOffset) {
    if (_tipDragObservationId != o.observationId) return;
    final camera = _mapController.camera;
    final origin = GeoPoint(o.latitude, o.longitude);
    final originScreen =
        camera.latLngToScreenOffset(ll.LatLng(o.latitude, o.longitude));
    // A fixed reference distance gives both the unit vector along the ray and
    // the screen scale in one projection, and stays well-conditioned even
    // when the current length is at the floor.
    const referenceMeters = 1000.0;
    final reference =
        destinationPoint(origin, o.trueNorthBearing ?? 0, referenceMeters);
    final referenceScreen = camera.latLngToScreenOffset(
      ll.LatLng(reference.latitude, reference.longitude),
    );
    final along = referenceScreen - originScreen;
    final alongLength = along.distance;
    if (!alongLength.isFinite || alongLength < 1e-3) return;
    final unit = along / alongLength;
    final pixelsPerMetre = alongLength / referenceMeters;
    final radialPixels = totalOffset.dx * unit.dx + totalOffset.dy * unit.dy;
    if (!radialPixels.isFinite) return;
    final next = (_tipDragStartRangeMeters + radialPixels / pixelsPerMetre)
        .clamp(_minBearingRangeMeters, _maxBearingRangeMeters);
    setState(() => _bearingRanges[o.observationId] = next);
  }

  void _endTipDrag() {
    if (_tipDragObservationId == null) return;
    setState(() => _tipDragObservationId = null);
  }

  /// Double-tapping a tip puts that one bearing back to the default length.
  void _resetBearingLength(String observationId) {
    if (!_bearingRanges.containsKey(observationId)) return;
    setState(() => _bearingRanges.remove(observationId));
  }

  /// Where a bearing's grab handle is drawn.
  ///
  /// Normally that is the tip. When the tip has been dragged off the edge of
  /// the viewport the handle is **clamped to the last point on the ray that
  /// is still grabbable**, because an off-screen handle cannot be grabbed and
  /// therefore cannot be dragged back — a bearing you can extend and not
  /// retract is a trap. Returns null when no part of the ray reaches that
  /// area, in which case there is nothing to clamp to and nothing to draw.
  ///
  /// **The clamp is a convenience, not the guarantee.** The handle lives
  /// inside the map's own layers, and the selection card, the record button
  /// and the banner column are drawn *over* the map — so the inset below
  /// keeps the clamped handle clear of the furniture that is certainly there
  /// while a bearing is selected, and cannot promise to clear furniture added
  /// later. The guaranteed way back from any length is **Reset bearing
  /// lengths** in Layers & Filters, which is reachable whatever the map looks
  /// like, plus a double-tap on the tip for one bearing at a time.
  ll.LatLng? _tipHandlePoint(Observation o) {
    final camera = _mapController.camera;
    final originScreen =
        camera.latLngToScreenOffset(ll.LatLng(o.latitude, o.longitude));
    final tip = destinationPoint(
      GeoPoint(o.latitude, o.longitude),
      o.trueNorthBearing ?? 0,
      _bearingRangeMeters(o.observationId),
    );
    final tipLatLng = ll.LatLng(tip.latitude, tip.longitude);
    final tipScreen = camera.latLngToScreenOffset(tipLatLng);
    if (!tipScreen.dx.isFinite || !tipScreen.dy.isFinite) return null;
    // Inset by the handle's own radius so a clamped handle sits fully on
    // screen, and further on the two edges that carry furniture: the "+"
    // record button and the map's right-hand control column on the right,
    // and the selection card along the bottom — whose height is measured
    // off the card itself rather than assumed.
    final size = camera.nonRotatedSize;
    // Task 11.131's number, now read off the whole transient bottom column
    // rather than the selection card alone — the column is what is drawn
    // over the map there (task 11.126 item B), and when a bearing is
    // selected the card is most of it. The permanent band and the "+" ride
    // *above* the column, so they are not in the handle's way.
    final bottomInset = 24 + _bottomPanelsHeight + 12;
    if (size.width <= 200 || size.height <= bottomInset + 80) {
      return tipLatLng;
    }
    final rect = Rect.fromLTRB(
      24,
      24,
      size.width - 88,
      size.height - bottomInset,
    );
    if (rect.contains(tipScreen)) return tipLatLng;
    final t = _lastParameterInside(rect, originScreen, tipScreen);
    if (t == null) return null;
    final clamped = originScreen + (tipScreen - originScreen) * t;
    final latLng = camera.screenOffsetToLatLng(clamped);
    if (!latLng.latitude.isFinite ||
        !latLng.longitude.isFinite ||
        latLng.latitude > 90.0 ||
        latLng.latitude < -90.0) {
      return null;
    }
    return latLng;
  }

  /// The largest `t` in [0, 1] for which `a + (b - a) * t` lies inside
  /// [rect] — Liang–Barsky clipping of the segment against the viewport.
  /// Null when the segment misses the rectangle entirely.
  static double? _lastParameterInside(Rect rect, Offset a, Offset b) {
    final d = b - a;
    var t0 = 0.0;
    var t1 = 1.0;
    final p = [-d.dx, d.dx, -d.dy, d.dy];
    final q = [
      a.dx - rect.left,
      rect.right - a.dx,
      a.dy - rect.top,
      rect.bottom - a.dy,
    ];
    for (var i = 0; i < 4; i++) {
      if (p[i] == 0) {
        if (q[i] < 0) return null; // Parallel to this edge and outside it.
        continue;
      }
      final r = q[i] / p[i];
      if (p[i] < 0) {
        if (r > t1) return null;
        if (r > t0) t0 = r;
      } else {
        if (r < t0) return null;
        if (r < t1) t1 = r;
      }
    }
    return t1 < 0 ? null : t1;
  }

  void _centerOnMyLocation(Position? gps) {
    if (gps == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Waiting for a GPS fix…')));
      return;
    }
    _mapController.move(ll.LatLng(gps.latitude, gps.longitude), _cameraZoom);
  }

  /// Recenters the map once whenever a *new* shared observation preview
  /// arrives (identity-compared, so it doesn't refight the user's own
  /// panning on every unrelated rebuild) — the "Show on map" action from
  /// Observation Sharing should actually bring the point into view.
  void _maybeRecenterOnShared(SharedObservation? shared) {
    if (shared == null || identical(shared, _centeredSharedIdentity)) return;
    _centeredSharedIdentity = shared;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.move(ll.LatLng(shared.latitude, shared.longitude), 15);
    });
  }

  /// Guards viewshed [OverlayImageLayer] bounds construction: DEM-grid
  /// extents feed straight into a [LatLngBounds] with no validation of their
  /// own, so if any coordinate math upstream ever produced a NaN/Infinity or
  /// an out-of-range latitude/longitude, constructing the bounds would throw
  /// (or, at extreme zoom, feed NaN into layout). Skipping the layer for one
  /// frame is harmless; letting an invalid bounds through is not.
  bool _isValidLatLngBoundsInput(
    double north,
    double south,
    double west,
    double east,
  ) {
    if (!north.isFinite ||
        !south.isFinite ||
        !west.isFinite ||
        !east.isFinite) {
      return false;
    }
    if (north > 90.0 || north < -90.0 || south > 90.0 || south < -90.0) {
      return false;
    }
    if (west > 180.0 || west < -180.0 || east > 180.0 || east < -180.0) {
      return false;
    }
    return true;
  }

  /// Where the map opens — task 11.103's fallback chain, shared with every
  /// other map in the app. See `map_camera_target.dart` for the order, the
  /// two decisions behind it, and why the "nothing supplied" case carries no
  /// coordinate.
  ///
  /// **What was here before**: device fix, then the project extent, then the
  /// *first* observation in an unordered list, then `LatLng(0, 0)`. Three
  /// things were wrong with that and only the last one was visible. The
  /// project extent outranked the recordings, which is backwards — an extent
  /// is drawn once at setup and the recordings are where somebody actually
  /// is. "The first observation" was whatever the query returned first, not
  /// the most recent — **and it only ever looked at bearings**, so a project
  /// whose recordings are truth points, estimates or non-detections fell past
  /// the step entirely. That is what happened on the Mac this was found on:
  /// it had a labelled truth point drawn on the map and still opened on the
  /// Atlantic. And the end of the chain was a valid coordinate in the Gulf of
  /// Guinea, so it reported that as confidently as it would have reported a
  /// fix.
  MapCameraTarget _cameraTarget(Project project, Position? gps, _MapData data) {
    return chooseMapCameraTarget(
      devicePosition:
          gps == null ? null : ll.LatLng(gps.latitude, gps.longitude),
      recorded: [
        for (final o in data.observations)
          MapPointInTime(o.latitude, o.longitude, o.timestampUtc),
        for (final e in data.estimates)
          MapPointInTime(e.latitude, e.longitude, e.timestampLocal.toUtc()),
        for (final l in data.tagLocations)
          MapPointInTime(l.latitude, l.longitude, l.timestampUtc),
        for (final n in data.nonDetections)
          MapPointInTime(n.latitude, n.longitude, n.timestampUtc),
      ],
      projectExtent: GeoExtent.fromProjectBbox(
        minLat: project.bboxMinLat,
        minLon: project.bboxMinLon,
        maxLat: project.bboxMaxLat,
        maxLon: project.bboxMaxLon,
      ),
    );
  }

  /// "Automatic viewshed from current location, displayed on map on open"
  /// (design doc) — computed once per screen visit, not on every GPS update.
  ///
  /// Task 11.95: started after the frame, not during it. This is reached from
  /// `build`, and [_computeViewshedAt] moves the shared computation-status
  /// provider to "Computing viewshed…" as its first act. Riverpod refuses a
  /// provider write from inside a build — two widgets watching one provider
  /// could otherwise come out of the same frame disagreeing about it — and
  /// because [_computeViewshedAt] is `async`, that refusal did not surface
  /// as a caught error: it completed the un-awaited future with an error
  /// nobody was listening to, which is the "unhandled asynchronous error on
  /// the map" `/w-02` saw and could not account for. Same one error, arriving
  /// by two routes.
  ///
  /// What it cost in the field, where the assertion is compiled out and the
  /// message never appears: the auto-viewshed never ran, and the bottom
  /// progress bar sat at "Computing viewshed…" for the rest of the session.
  ///
  /// The post-frame deferral is the same shape [_maybeRecenterOnShared] and
  /// [_recenterOnce] already use for their own out-of-build side effects.
  void _maybeAutoComputeViewshed(Project project, Position? gps) {
    if (_autoViewshedAttempted || gps == null || _viewshedBusy) return;
    _autoViewshedAttempted = true;
    final lat = gps.latitude;
    final lon = gps.longitude;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // On open, quietly try the current location; if there's no elevation
      // coverage there, don't nag — the user only gets prompted to download
      // when they actively ask for a viewshed (tap-to-predict below).
      unawaited(
        _computeViewshedAt(
          lat,
          lon,
          autoEnableLayer: true,
          silentIfNoCoverage: true,
        ),
      );
    });
  }

  void _onMapTap(Project project, ll.LatLng point, _MapData data) {
    if (_measureMode) {
      setState(() {
        // A third tap starts a fresh measurement rather than requiring an
        // explicit "Clear" first — the common field-use rhythm is tap, tap,
        // read the result, tap-tap-again for the next pair.
        if (_measurePoints.length >= 2) _measurePoints.clear();
        _measurePoints.add(point);
      });
      return;
    }
    if (_predictMode) {
      _computeViewshedAt(
        point.latitude,
        point.longitude,
        autoEnableLayer: true,
      );
      return;
    }
    _selectAtPoint(point, data);
  }

  /// Press-and-hold anywhere on the map surfaces that point's lat/lon with a
  /// "Navigate here" action, reusing the same bottom info panel as a tapped
  /// recording (see `_FreePointSelection`).
  void _onMapLongPress(ll.LatLng point) {
    if (_measureMode || _predictMode) return;
    setState(() => _selection = _FreePointSelection(point));
  }

  /// Sets the shared navigation target (Main Map's live line/banner + the
  /// Compass screen's bearing/distance indicator) and closes the info panel,
  /// since starting navigation is the point of tapping the button.
  void _navigateTo(double lat, double lon, String? label) {
    ref.read(navigationTargetProvider.notifier).set(
          NavigationTarget(latitude: lat, longitude: lon, label: label),
        );
    setState(() => _selection = null);
  }

  /// Task 11.209's "Copy for TriTrack" on the map card. **Reuses the exact
  /// same encoder as `log_screen.dart`'s per-row Copy** —
  /// [buildTriTrackClipboardPayload] — so a payload copied from either screen
  /// for the same observation is byte-identical
  /// (`test/data/sharing/tritrack_copy_parity_test.dart`). Only offered for a
  /// bearing (`_ObsSelection`): estimates and truth points are not
  /// `Observations` rows and have no TriTrack encoding to reuse.
  Future<void> _copyForTriTrack(BuildContext context, Observation o) async {
    final copied = await runGuardedWrite(
      context,
      // Sharing reads a record out and writes nothing, so no permission
      // governs it and a refusal here would be a bug (task 11.137).
      refused: null,
      write: () async {
        final tagRepo = await ref.read(tagRepositoryProvider.future);
        final userRepo = await ref.read(userRepositoryProvider.future);
        final tagVersionRepo = await ref.read(tagVersionRepositoryProvider.future);
        final tagId = o.tagId;
        final tag = tagId == null
            ? null
            : await tagRepo.findById(
                tagId,
                projectId: o.projectId,
                includeDeleted: true,
              );
        final observer = await userRepo.findById(o.userId, includeDeleted: true);
        if (tag == null || observer == null) {
          throw StateError('Missing tag or observer info for this bearing.');
        }
        final payload = await buildTriTrackClipboardPayload(
          tagVersionRepo: tagVersionRepo,
          observation: o,
          tag: tag,
          observer: observer,
        );
        await Clipboard.setData(ClipboardData(text: payload));
      },
      failed: 'Could not copy this observation. Try again, and report it if '
          'this keeps happening.',
    );
    if (!copied || !context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copied — paste into any messaging app')));
  }

  /// Selects the nearest visible recording (estimate / tag location marker, or
  /// bearing ray) to a tap, in screen pixels via the live camera; taps on
  /// empty map clear the selection. Point markers win ties over rays since
  /// they're checked first at the same threshold.
  void _selectAtPoint(ll.LatLng point, _MapData data) {
    final camera = _mapController.camera;
    final tap = camera.latLngToScreenOffset(point);

    // **A tap on a marker's drawn shape selects that marker** (task 11.319),
    // before "nearest wins" is asked at all.
    //
    // An estimated position and the truth point found for it are usually
    // close: 13 screen points apart at a survey zoom, less than the 24-point
    // radius below. Asked only by distance to each marker's *point*, a finger
    // on the edge of the truth point's 16-point square that faces the
    // estimate is nearer the estimate's point than its own once the two are
    // under 16 points apart — a strip 8 minus half the separation wide, so
    // 1.5 points at 13 apart and the whole near half at 8 — and the estimate's
    // card opened for a tap on the thing drawn under the finger. The truth
    // point is painted after the estimate, so it is on top where they overlap
    // and is asked first; the estimate's ring is second. Anywhere that is
    // neither, the nearest marker or ray within the radius wins exactly as
    // before.
    final onShape = _markerUnderFinger(camera, tap, data);
    if (onShape != null) {
      setState(() {
        _selection = onShape;
        if (onShape is _EstSelection) _showSelectedEllipse = true;
      });
      return;
    }

    _MapSelection? best;
    var bestDist = 24.0; // px

    if (_showEstimates) {
      for (final e in data.estimates) {
        if (!(_visible(e.tagId, e.timestampLocal, data.deployments) &&
            _inTimeWindow(e.timestampLocal))) {
          continue;
        }
        final d =
            (camera.latLngToScreenOffset(ll.LatLng(e.latitude, e.longitude)) -
                    tap)
                .distance;
        if (d < bestDist) {
          bestDist = d;
          best = _EstSelection(e);
        }
      }
    }
    if (_showTagLocations) {
      for (final t in data.tagLocations) {
        if (!(_visible(t.tagId, t.timestampUtc, data.deployments) &&
            _inTimeWindow(t.timestampUtc))) {
          continue;
        }
        final d =
            (camera.latLngToScreenOffset(ll.LatLng(t.latitude, t.longitude)) -
                    tap)
                .distance;
        if (d < bestDist) {
          bestDist = d;
          best = _TagLocSelection(t);
        }
      }
    }
    if (_showRays) {
      for (final o in data.observations) {
        if (!(_visible(o.tagId, o.timestampUtc, data.deployments) &&
            _inTimeWindow(o.timestampUtc))) {
          continue;
        }
        final origin = camera.latLngToScreenOffset(
          ll.LatLng(o.latitude, o.longitude),
        );
        final dest = destinationPoint(
          GeoPoint(o.latitude, o.longitude),
          o.trueNorthBearing!,
          _bearingRangeMeters(o.observationId),
        );
        final end = camera.latLngToScreenOffset(
          ll.LatLng(dest.latitude, dest.longitude),
        );
        final d = _distanceToSegment(tap, origin, end);
        if (d < bestDist) {
          bestDist = d;
          best = _ObsSelection(o);
        }
      }
    }

    setState(() {
      _selection = best;
      if (best is _EstSelection) _showSelectedEllipse = true;
    });
  }

  /// The marker whose **drawn shape** contains [tap], topmost first, or null.
  /// See [_selectAtPoint] for why this is asked before distance.
  ///
  /// The shapes are read from the marker widgets' own size constants, so a
  /// marker redrawn larger is hit as larger. Truth points are square
  /// ([_TagLocationMarker.glyphSize] across, so half that from the point in
  /// each direction) and estimates are round ([_EstimateMarker.glyphSize]
  /// across). Truth points are checked first because they are painted last.
  _MapSelection? _markerUnderFinger(
    MapCamera camera,
    Offset tap,
    _MapData data,
  ) {
    if (_showTagLocations) {
      _TagLocSelection? hit;
      var hitDist = double.infinity;
      for (final t in data.tagLocations) {
        if (!(_visible(t.tagId, t.timestampUtc, data.deployments) &&
            _inTimeWindow(t.timestampUtc))) {
          continue;
        }
        final off =
            camera.latLngToScreenOffset(ll.LatLng(t.latitude, t.longitude)) -
            tap;
        final half = _TagLocationMarker.glyphSize / 2;
        if (off.dx.abs() > half || off.dy.abs() > half) continue;
        if (off.distance < hitDist) {
          hitDist = off.distance;
          hit = _TagLocSelection(t);
        }
      }
      if (hit != null) return hit;
    }
    if (_showEstimates) {
      _EstSelection? hit;
      var hitDist = double.infinity;
      for (final e in data.estimates) {
        if (!(_visible(e.tagId, e.timestampLocal, data.deployments) &&
            _inTimeWindow(e.timestampLocal))) {
          continue;
        }
        final d =
            (camera.latLngToScreenOffset(ll.LatLng(e.latitude, e.longitude)) -
                    tap)
                .distance;
        if (d > _EstimateMarker.glyphSize / 2) continue;
        if (d < hitDist) {
          hitDist = d;
          hit = _EstSelection(e);
        }
      }
      if (hit != null) return hit;
    }
    return null;
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lenSq == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq;
    t = t.clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  /// The consolidated "Layers & Filters" sheet — one entry point for every
  /// map control that isn't a frequent quick-action, so the map itself stays
  /// uncluttered. Sections: which layers are drawn, viewshed tools, which tags
  /// are visible, and a time window. Mutations apply live to the map behind the
  /// sheet (and clear any selection whose item may no longer be shown).
  Future<void> _showLayersFiltersSheet(BuildContext context, _MapData data) {
    return showModalBottomSheet<void>(
      context: context,
      // Non-blocking-feeling: a draggable sheet the user can pull down to a
      // sliver so they can watch layers/filters take effect on the map while
      // toggling — the old fixed 75%-tall sheet hid most of the map, which
      // made toggles look like they "did nothing."
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheet) {
            void apply(VoidCallback fn) {
              setState(fn);
              setSheet(() {});
            }

            Widget layerSwitch(String label, bool value, ValueChanged<bool> onChanged,
                {bool enabled = true, String? subtitle}) {
              return SwitchListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                title: Text(label, style: TextStyle(color: enabled ? null : Theme.of(context).disabledColor)),
                subtitle: subtitle == null ? null : Text(subtitle),
                value: value,
                onChanged: enabled ? onChanged : null,
              );
            }

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.5,
              minChildSize: 0.25,
              maxChildSize: 0.92,
              snap: true,
              builder: (context, scrollController) => ListView(
                controller: scrollController,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(top: 8, bottom: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
                    child: Text('Layers & Filters',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  ),
                  const _SheetSectionLabel('LAYERS'),
                  layerSwitch('Bearings', _showRays, (v) => apply(() {
                        _showRays = v;
                        _selection = null;
                      })),
                  layerSwitch('Uncertainty wedges', _showWedges,
                      (v) => apply(() => _showWedges = v)),
                  // Task 11.131: the way back from any number of dragged
                  // lengths at once. Individually, a double-tap on a tip
                  // resets that one. Disabled — rather than hidden — when
                  // nothing has been dragged, so it reads as "there is
                  // nothing to reset" instead of as a control that does not
                  // exist.
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    title: Text(
                      'Reset bearing lengths',
                      style: TextStyle(
                        color: _bearingRanges.isEmpty
                            ? Theme.of(context).disabledColor
                            : null,
                      ),
                    ),
                    subtitle: const Text(
                      'Press and hold a selected bearing’s tip to drag its '
                      'length. Lengths are for display only and reset when '
                      'you leave the map.',
                    ),
                    onTap: _bearingRanges.isEmpty
                        ? null
                        : () => apply(_bearingRanges.clear),
                  ),
                  layerSwitch('Estimated positions', _showEstimates, (v) => apply(() {
                        _showEstimates = v;
                        _selection = null;
                      })),
                  layerSwitch('Actual tag locations', _showTagLocations, (v) => apply(() {
                        _showTagLocations = v;
                        _selection = null;
                      })),
                  layerSwitch('No-signal records', _showNonDetections,
                      (v) => apply(() => _showNonDetections = v)),
                  // The incomplete-terrain sentence is repeated here on
                  // purpose (task 11.142). The snackbar that says it at the
                  // moment of the computation is gone in seconds; this is the
                  // control a person opens to ask what the viewshed *is*, so
                  // it is where the caveat has to still be readable an hour
                  // later.
                  layerSwitch('Viewshed', _showViewshed,
                      (v) => apply(() => _showViewshed = v),
                      enabled: _viewshedResult != null,
                      subtitle: _viewshedResult?.terrainIsIncomplete ?? false
                          ? kPartialTerrainCaveat
                          : null),
                  layerSwitch('Legend', _showLegend, (v) => apply(() => _showLegend = v)),
                  const _SheetSectionLabel('VIEWSHED TOOLS'),
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    leading: Icon(Icons.visibility,
                        color: _predictMode ? Theme.of(context).colorScheme.primary : null),
                    title: const Text('Predict viewshed at a tapped point'),
                    trailing: Switch(
                      value: _predictMode,
                      onChanged: (v) {
                        apply(() {
                          _predictMode = v;
                          if (v) {
                            _selection = null;
                            _liveViewshed = false;
                          }
                        });
                        if (v) Navigator.of(sheetContext).pop();
                      },
                    ),
                  ),
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    leading: Icon(Icons.my_location,
                        color: _liveViewshed
                            ? Theme.of(context).colorScheme.primary
                            : null),
                    title: const Text('Live viewshed (follow GPS)'),
                    subtitle:
                        const Text('Recomputes from your position as you move'),
                    trailing: Switch(
                      value: _liveViewshed,
                      onChanged: (v) {
                        apply(() {
                          _liveViewshed = v;
                          if (v) {
                            _predictMode = false;
                            _selection = null;
                          }
                        });
                        if (v) {
                          Navigator.of(sheetContext).pop();
                          final gps = ref.read(gpsPositionProvider).value;
                          if (gps != null) {
                            _computeViewshedAt(
                              gps.latitude,
                              gps.longitude,
                              autoEnableLayer: true,
                              silentIfNoCoverage: true,
                            );
                          }
                        }
                      },
                    ),
                  ),
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    leading: const Icon(Icons.height),
                    title: const Text('Observer height & opacity'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _showObserverHeightSheet();
                    },
                  ),
                  const _SheetSectionLabel('TAGS'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: _hiddenTagIds.isEmpty && _hiddenAnimalIds.isEmpty
                              ? null
                              : () => apply(() {
                                    _hiddenTagIds.clear();
                                    _hiddenAnimalIds.clear();
                                  }),
                          child: const Text('Show all'),
                        ),
                        TextButton(
                          onPressed: () => apply(() {
                            _hiddenTagIds
                              ..clear()
                              ..addAll(data.tags.map((t) => t.tagId));
                            _hiddenAnimalIds
                              ..clear()
                              ..addAll(data.individuals.map((a) => a.individualId));
                            _selection = null;
                          }),
                          child: const Text('Hide all'),
                        ),
                      ],
                    ),
                  ),
                  if (data.tags.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      child: Text('No tags in this project.', style: TextStyle(fontSize: 12)),
                    ),
                  // Task 11.247: the animal's checkbox now filters **per ray**
                  // — a bearing is hers when the deployment covering its
                  // timestamp names her (`DeploymentRepository
                  // .animalForObservationIn`, the Log's own derivation, never
                  // a second one) — not "every collar she has ever worn".
                  // A collar that fell off and kept transmitting no longer
                  // counts against her when she's shown, and no longer
                  // disappears when she's hidden.
                  //
                  // Each collar beneath still has its own equipment-level
                  // checkbox (task 11.241) — a separate axis, for hiding one
                  // specific collar's readings (a known-bad receiver, say)
                  // regardless of whose deployment covers them. It always
                  // wins: a collar hidden there is hidden everywhere, whoever
                  // it belongs to. Collars naming no animal follow, under
                  // their own label, unaffected by any animal checkbox.
                  for (final group in _animalGroupsOf(data)) ...[
                    CheckboxListTile(
                      key: ValueKey('map_filter_animal_${group.animal.individualId}'),
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                      controlAffinity: ListTileControlAffinity.leading,
                      value: !_hiddenAnimalIds.contains(group.animal.individualId),
                      onChanged: (_) => apply(() {
                        final id = group.animal.individualId;
                        if (_hiddenAnimalIds.contains(id)) {
                          _hiddenAnimalIds.remove(id);
                        } else {
                          _hiddenAnimalIds.add(id);
                          _selection = null;
                        }
                      }),
                      secondary: TagColorSwatch(colorHex: group.animal.colorHex),
                      title: Text(
                        group.animal.name,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    for (final t in group.collars) _tagFilterTile(t, apply, indented: true),
                  ],
                  if (_ungroupedTags(data).isNotEmpty) ...[
                    if (data.individuals.isNotEmpty)
                      const _SheetSectionLabel('TAGS WITH NO ANIMAL'),
                    for (final t in _ungroupedTags(data)) _tagFilterTile(t, apply),
                  ],
                  const _SheetSectionLabel('TIME WINDOW'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final w in _MapTimeWindow.values)
                          ChoiceChip(
                            label: Text(w == _MapTimeWindow.custom && _customRange != null
                                ? '${_customRange!.start.month}/${_customRange!.start.day}–${_customRange!.end.month}/${_customRange!.end.day}'
                                : w.label),
                            selected: _timeWindow == w,
                            onSelected: (_) async {
                              if (w == _MapTimeWindow.custom) {
                                final now = DateTime.now();
                                final picked = await showDateRangePicker(
                                  context: sheetContext,
                                  firstDate: DateTime(now.year - 5),
                                  lastDate: DateTime(now.year + 1),
                                  initialDateRange: _customRange,
                                );
                                if (picked != null) {
                                  apply(() {
                                    _customRange = picked;
                                    _timeWindow = _MapTimeWindow.custom;
                                    _selection = null;
                                  });
                                }
                              } else {
                                apply(() {
                                  _timeWindow = w;
                                  _selection = null;
                                });
                              }
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Opens a bottom sheet letting the user set the observer/antenna height
  /// AGL (0-122 m, e.g. drone altitude) and the viewshed overlay's opacity
  /// (0-100%). If a viewshed is already showing, changing height recomputes
  /// it at the same observer point so the overlay reflects the change
  /// immediately; changing opacity just re-draws the existing overlay at the
  /// new value (no recompute needed since it's applied live at draw time).
  Future<void> _showObserverHeightSheet() async {
    var sheetHeight = _observerHeightMeters;
    var sheetOpacity = _viewshedOpacity;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Observer / antenna height above ground (AGL)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text('${sheetHeight.round()} m — e.g. drone altitude'),
                  Slider(
                    value: sheetHeight,
                    min: 0,
                    max: 122,
                    divisions: 122,
                    label: '${sheetHeight.round()} m',
                    onChanged: (v) => setSheetState(() => sheetHeight = v),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Viewshed opacity',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text('${(sheetOpacity * 100).round()}%'),
                  Slider(
                    value: sheetOpacity,
                    min: 0,
                    max: 1,
                    divisions: 20,
                    label: '${(sheetOpacity * 100).round()}%',
                    onChanged: (v) {
                      setSheetState(() => sheetOpacity = v);
                      setState(() => _viewshedOpacity = v);
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    if (sheetHeight != _observerHeightMeters) {
      setState(() => _observerHeightMeters = sheetHeight);
      final observer = _viewshedObserver;
      if (observer != null) {
        await _computeViewshedAt(observer.latitude, observer.longitude);
      }
    }
  }

  /// Auto-downloads any missing DEM terrain covering the disc of
  /// [radiusMeters] around [center] (the viewshed's range), then keeps the
  /// auto-cache within the user's size limit.
  ///
  /// Only the local disc is fetched — never the whole visible map, which could
  /// be enormous. Fetched terrain lands in the shared [DemTileStore] (so it's
  /// reused and can complete a nearby permanent region) but is treated as
  /// ephemeral: after fetching, the disc's tiles are touched (most-recently-
  /// used) and least-recently-used unprotected tiles beyond the limit are
  /// evicted. Tiles backing a saved offline region are protected. A failed
  /// fetch (offline) just stops early; the caller handles missing coverage.
  Future<void> _ensureTerrainForRegion(
    DemTileStore store,
    ll.LatLng center,
    double radiusMeters,
    ComputationStatusNotifier statusNotifier,
  ) async {
    const metersPerDegLat = 111320.0;
    final dLat = radiusMeters / metersPerDegLat;
    final cosLat = math.cos(center.latitude * math.pi / 180.0).abs();
    final dLon = radiusMeters / (metersPerDegLat * math.max(cosLat, 1e-6));
    final wanted = store.tilesIntersectingBounds(
      minLat: center.latitude - dLat,
      minLon: center.longitude - dLon,
      maxLat: center.latitude + dLat,
      maxLon: center.longitude + dLon,
    );
    // **Not "which of these has no file"** (task 11.143): a tile that arrived
    // half-written, or with holes in it and attempts left, is on disk and is
    // exactly what this loop has to ask for again.
    final missing = <DemTileId>[];
    for (final id in wanted) {
      if (await store.needsFetch(id)) missing.add(id);
    }
    // Shared across every DEM tile in this region fill (task 11.281):
    // adjacent 0.1° DEM tiles overlap in which terrarium tiles cover them,
    // and without one cache spanning the whole loop each overlapping
    // terrarium tile was re-fetched by every DEM tile that needed it — 380
    // requests for 72 DEM tiles where only 143 terrarium tiles are distinct.
    final terrainCache = TerrainTileCache();
    for (var i = 0; i < missing.length; i++) {
      // **The count is how many are done, not which one is in flight.** It
      // used to show `i + 1` before starting tile i, so it reached
      // "72/72" with the last fetch still running and sat there — a readout
      // that has arrived at its own denominator and stopped is the most
      // confusing state to leave somebody in, because it looks finished.
      statusNotifier.start('Downloading terrain… $i/${missing.length}');
      try {
        final grid = await DemTileFetcher.fetchTile(missing[i], cache: terrainCache);
        // **A tile that came back with nothing in it is not saved** (task
        // 11.142). [DemTileFetcher.fetchTile] does not throw when its terrain
        // requests fail — it leaves the cells it could not fill as noData and
        // hands back a grid of the right shape, deliberately, so one missing
        // source tile does not fail the whole DEM tile. Saving that grid when
        // *every* cell is empty writes a file that used to read as coverage.
        // [DemTileStore.saveTile] now refuses such a grid itself; this check
        // stays because throwing on the expected offline case would make the
        // `catch` below stop a loop that should just carry on. Measured in
        // `test/viewshed/partial_terrain_viewshed_test.dart`.
        if (grid.dataCoverageFraction > 0) await store.saveTile(missing[i], grid);
      } catch (_) {
        // A save that failed — a full disk, a directory that will not open.
        // **Not the offline case**, whatever this used to say: a fetch failure
        // does not arrive here at all, it arrives as noData cells above. Stop
        // and let compose proceed with whatever coverage exists; the caller
        // measures that coverage and says so on screen.
        break;
      }
    }
    // Keep the active disc; bound the rest of the auto-cache.
    await store.touchTiles(wanted);
    try {
      final limitMb = await ref.read(terrainCacheLimitProvider.future);
      final protected = await _protectedDemTiles(store);
      await store.enforceCacheLimit(
        maxBytes: limitMb * 1024 * 1024,
        protectedIds: protected,
      );
    } catch (_) {
      // Eviction is best-effort; never fail the viewshed over housekeeping.
    }
  }

  /// DEM tiles covered by a saved offline region (kind == dem). These are
  /// permanent coverage the user explicitly downloaded and must never be
  /// evicted by the auto-cache limit.
  Future<Set<DemTileId>> _protectedDemTiles(DemTileStore store) async {
    final regions = await ref.read(offlineRegionsProvider.future);
    final protected = <DemTileId>{};
    for (final r in regions) {
      if (r.kind == OfflineRegionKind.dem) {
        protected.addAll(store.tilesIntersectingPolygon(r.polygon));
      }
    }
    return protected;
  }

  /// Composes an elevation grid from the tiled DEM store around ([lat],[lon])
  /// (out to the viewshed's max range) and runs the viewshed. Reads the new
  /// per-tile downloaded elevation — not the legacy single-file DEM — so it
  /// reflects whatever the user downloaded on the Offline Data Map.
  Future<void> _computeViewshedAt(
    double lat,
    double lon, {
    bool autoEnableLayer = false,
    bool silentIfNoCoverage = false,
    bool autoFetchTerrain = true,
  }) async {
    // Task 11.95: everything is inside the `try`, including the three lines
    // that used to run ahead of it. Every caller starts this and walks away
    // — the auto-start above, the live-viewshed GPS listener, tap-to-predict
    // — so anything thrown outside the `try` became an unhandled
    // asynchronous error instead of a failed computation, and skipped the
    // `finally` that clears the busy flag and the progress bar with it. A
    // computation that cannot report its own failure is worse than one that
    // fails.
    ComputationStatusNotifier? started;
    try {
      setState(() => _viewshedBusy = true);
      final statusNotifier = ref.read(computationStatusProvider.notifier);
      started = statusNotifier;
      statusNotifier.start('Computing viewshed…');
      final config = ViewshedConfig(
        observerHeightMeters: _observerHeightMeters,
      );
      final store = DemTileStore();
      // Stream terrain in on demand — like the map tiles — for JUST the range
      // disc around the observer (not the whole viewport), when online. Failed
      // fetches (offline) fall through to the "no data" path below.
      if (autoFetchTerrain) {
        await _ensureTerrainForRegion(
          store,
          ll.LatLng(lat, lon),
          config.maxRangeMeters,
          statusNotifier,
        );
      }
      statusNotifier.start('Computing viewshed…');
      final dem = await store.composeForRegion(
        center: ll.LatLng(lat, lon),
        radiusMeters: config.maxRangeMeters,
      );
      if (dem == null) {
        // No DEM tiles cover this area at all. Clear the status bar and, when
        // the user actively asked, tell them plainly and offer to download.
        statusNotifier.reset();
        if (!silentIfNoCoverage && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'No elevation data downloaded for this area.',
              ),
              action: SnackBarAction(
                label: 'Download',
                onPressed: () => context.push('/more/offline-data-map'),
              ),
            ),
          );
        }
        return;
      }
      final result = await computeViewshedInBackground(
        dem,
        lat,
        lon,
        config: config,
      ).timeout(kViewshedComputeDeadline);
      if (!result.hasResult) {
        final message = result.status == ViewshedStatus.observerOutOfCoverage
            ? 'Outside downloaded elevation coverage.'
            : 'No elevation data at that point.';
        // Resolve the status notifier before checking `mounted` — it's
        // global (survives navigation away from this screen), so bailing
        // out on an unmount here would leave "Computing viewshed…" stuck
        // showing forever with no way to clear it.
        statusNotifier.fail('Computing viewshed…', message);
        if (!silentIfNoCoverage && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
        return;
      }
      statusNotifier.complete('Computing viewshed…');
      if (!mounted) return;
      // Task 11.142: said at the moment the claim is made. `silentIfNoCoverage`
      // is the flag every *automatic* computation sets — the auto-start on
      // opening the map and the live-viewshed GPS listener — and it is
      // respected here for the same reason it is respected above: a snackbar
      // nobody asked for, arriving on every GPS fix, is one people learn to
      // dismiss without reading.
      if (!silentIfNoCoverage && result.terrainIsIncomplete) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(kPartialTerrainCaveat),
            duration: const Duration(seconds: 10),
            action: SnackBarAction(
              label: 'Download',
              onPressed: () => context.push('/more/offline-data-map'),
            ),
          ),
        );
      }
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final colors = isDark ? TriTrackColors.dark : TriTrackColors.light;
      final png = renderViewshedPng(
        result,
        argbColor: colors.viewshedOverlay.toARGB32(),
      );
      setState(() {
        _viewshedResult = result;
        _viewshedPng = png;
        _viewshedObserver = ll.LatLng(lat, lon);
        if (autoEnableLayer) _showViewshed = true;
      });
    } catch (e) {
      // The 20-second `.timeout` above is the common failure here, not the
      // exception: a large downloaded elevation area makes the raster slow,
      // and what a person used to be shown for it was the literal text
      // `TimeoutException after 0:00:20.000000`. It gets its own sentence
      // because the cause and the thing to do about it are both specific.
      final message = e is TimeoutException
          ? 'The viewshed took too long and was stopped. Try again from a '
                'spot with less elevation data around it, or turn the '
                'Viewshed layer off in the layers menu.'
          : describeFailure(
              e,
              fallback:
                  'Could not work out what is visible from here. Try again, '
                  'or turn the Viewshed layer off in the layers menu.',
            );
      // Null only if the throw beat the `ref.read` above, in which case
      // there is no status bar showing "Computing viewshed…" to clear.
      started?.fail('Computing viewshed…', message);
    } finally {
      if (mounted) setState(() => _viewshedBusy = false);
    }
  }
}

/// **What a viewshed drawn from part of the terrain has to say about itself**
/// — task 11.142.
///
/// A DEM tile that failed to download is a hole, and the line-of-sight sweep
/// stops a ray at a hole exactly as it stops one at the edge of the world.
/// Everything past the hole is therefore drawn as *not visible* — the same
/// raster a mountain would produce. **That is a claim about where an animal
/// could be heard from, and it is wrong in the direction that matters:** it
/// says "you could not have heard the collar there" about ground nobody has
/// any elevation for.
///
/// **The overlay is not hidden**, because a viewshed over part of the terrain
/// is genuinely useful to somebody who knows that is what it is. What is not
/// acceptable is presenting it as complete, so this sentence travels with it:
/// on the snackbar at the moment it is computed, and on the Viewshed switch in
/// the layers sheet for as long as it is the current answer.
///
/// Names no cause, because the code does not know one — a tile can be missing
/// because the download failed, because there was no signal, or because that
/// square has never been fetched. It names the consequence and the action,
/// which are the same for all three.
const String kPartialTerrainCaveat =
    'Some elevation data here is missing, so ground with no elevation is '
    'drawn as not visible, which may be wrong. Download this area on the '
    'Offline Data Map and work the viewshed out again.';

class _NoProjectEmptyState extends StatelessWidget {
  const _NoProjectEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined, size: 40),
            const SizedBox(height: 12),
            Text(
              'No active project',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.push('/more/project-setup'),
              child: const Text('Set up project'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The width of the box a point marker and its label are drawn in.
///
/// Was 120 when the label was "Sage · 150.284 MHz". Task 11.319 put a kind
/// word in front of it, so an estimate now reads "Estimate · Sage · 150.284
/// MHz" — 11 characters longer at 10-point bold — and the box grew to match
/// rather than ellipsizing the frequency, which is the part that tells two
/// collars on one animal apart. The marker is not a control, so a wider box
/// changes nothing but how much room the text has.
const double _markerLabelWidth = 176;

/// The height of the box a point marker (estimate, truth point, shared
/// bearing) is drawn in: its glyph on top, then its label at the reader's text
/// size ([_MarkerLabel.heightIn]).
///
/// **Task 11.332 item 6.** This was a fixed 36 px, which held the glyph and a
/// label at the default text size with nothing to spare, so from one notch up
/// the column overflowed its box by 2, 4 and 5 px (found by task 11.338). In a
/// release build that is a pin drawn a few pixels off and nothing logged. The
/// box now grows with the label, and [_pointMarkerAlignment] keeps the glyph's
/// center on the point whatever the box's height.
double _pointMarkerHeight(double glyphSize, double labelHeight) =>
    (glyphSize + labelHeight).ceilToDouble();

/// The `Marker.alignment` that puts the center of a [glyphSize] glyph, drawn
/// at the top of a [_pointMarkerHeight] box, on the marker's point.
///
/// flutter_map puts the point `height * (1 - y) / 2` from the top of the box,
/// so the glyph's center (`glyphSize / 2`) is there when
/// `y = 1 - glyphSize / height`. At the old fixed 36 px that is the
/// `Alignment(0, 0.5)` (18 px ring) and `Alignment(0, 10 / 18)` (16 px square)
/// these markers used to carry as constants.
Alignment _pointMarkerAlignment(double glyphSize, double labelHeight) =>
    Alignment(0, 1 - glyphSize / _pointMarkerHeight(glyphSize, labelHeight));

/// The text under an estimated position or a truth point: which of the two it
/// is, then the collar.
///
/// **Deliberately not the info cards' own words** ("Estimated position ·",
/// "Truth point ·"). The screenshot harness decides a card is open by looking
/// for its title as text, and a label that contained the title would make
/// that check pass with the card closed; `map_screen_test.dart` pins the
/// difference.
String _markerLabel(String kind, _TagRow? tag) =>
    '$kind · ${tag?.tagName ?? '?'} · '
    '${tag?.frequencyMhz.toStringAsFixed(3) ?? '?'} MHz';

class _EstimateMarker extends StatelessWidget {
  const _EstimateMarker({required this.color, required this.label});
  final Color color;
  final String label;

  /// The ring's diameter, which `_markerUnderFinger` reads as its hit shape.
  static const double glyphSize = 18;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: glyphSize,
          height: glyphSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(color: color, width: 2.5),
          ),
        ),
        _MarkerLabel(text: label, color: color),
      ],
    );
  }
}

class _TagLocationMarker extends StatelessWidget {
  const _TagLocationMarker({required this.color, required this.label});
  final Color color;
  final String label;

  /// The square's side, which `_markerUnderFinger` reads as its hit shape.
  static const double glyphSize = 16;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: glyphSize,
          height: glyphSize,
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 2.5),
          ),
        ),
        _MarkerLabel(text: label, color: color),
      ],
    );
  }
}

/// A temporary "pasted from another device" marker (design doc §10: "preview
/// on map as a temporary overlay") — a dashed-look ring distinguishes it at a
/// glance from the app's own solid-outline observation markers, on top of the
/// "shared" text label (never color alone, per the design doc's rule).
class _SharedObservationMarker extends StatelessWidget {
  const _SharedObservationMarker({required this.label});
  final String label;

  /// The ring's diameter; [_pointMarkerHeight] sizes the marker's box from it.
  static const double glyphSize = 18;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: glyphSize,
          height: glyphSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.deepPurple,
              width: 2.5,
              style: BorderStyle.solid,
            ),
          ),
          child: const Icon(Icons.share, size: 10, color: Colors.deepPurple),
        ),
        _MarkerLabel(text: label, color: Colors.deepPurple),
      ],
    );
  }
}

class _SharedObservationBanner extends StatelessWidget {
  const _SharedObservationBanner({
    required this.tagName,
    required this.onClear,
  });
  final String tagName;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.deepPurple.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.share, size: 16, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Previewing shared observation: $tagName',
                style: const TextStyle(color: Colors.white, fontSize: 12),
                // One line on purpose (task 11.332 lists it): the tag's name
                // is the part that can be long, and the card below names it.
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: const Text('Clear'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MarkerLabel extends StatelessWidget {
  const _MarkerLabel({required this.text, required this.color});
  final String text;
  final Color color;

  static const double _marginTop = 2;
  static const double _paddingVertical = 1;
  static const TextStyle _style =
      TextStyle(fontSize: 10, fontWeight: FontWeight.w700);

  /// The label's whole style, resolved from the theme rather than inherited.
  ///
  /// **Not `DefaultTextStyle.of(context)`.** [heightIn] is called from the
  /// screen's own build, above the `Scaffold`, where the ambient style is
  /// `MaterialApp`'s debug fallback; the label itself sits under the
  /// Scaffold's `Material`, whose ambient style is the theme's `bodyMedium`.
  /// Measuring in one and drawing in the other overflowed by 4-6 px on the
  /// first try (`CLAUDE.md` defect vocabulary 78). So both read this.
  static TextStyle _resolved(BuildContext context, {Color? color}) =>
      (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
          .merge(_style.copyWith(color: color));

  /// How tall this label is at [context]'s text size: its gap above, its
  /// padding, and **one line of text, measured** rather than predicted, in
  /// the style the `Text` below is drawn in.
  ///
  /// One line because the label is a deliberate one-line truncation
  /// (`maxLines: 1`). It is a tag name and a frequency, and the info card the
  /// marker opens says it whole.
  static double heightIn(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'Estimate · Sage · 150.284 MHz',
        style: _resolved(context),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final line = painter.height;
    painter.dispose();
    return _marginTop + 2 * _paddingVertical + line;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: _marginTop),
      padding: const EdgeInsets.symmetric(
        horizontal: 4,
        vertical: _paddingVertical,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: _resolved(context, color: color),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Task 11.94/11.101 exemption: this, the layers button, and the small
/// close/clear icon buttons scattered on this map (search chip, refusal
/// banner, selection card) are labelled only by `tooltip:`. See
/// `map_furniture.dart`'s `MeasureButton` doc comment for the reasoning —
/// same cluster, same trade, not repeated at every site.
class _MyLocationButton extends StatelessWidget {
  const _MyLocationButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: IconButton(
        tooltip: 'Center on my location',
        icon: const Icon(Icons.my_location),
        onPressed: onPressed,
      ),
    );
  }
}

/// Opens the consolidated Layers & Filters sheet. Shows an accent dot when a
/// tag/time filter is active so the user knows the map is filtered.
class _LayersFiltersButton extends StatelessWidget {
  const _LayersFiltersButton({required this.active, required this.onPressed});
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: IconButton(
        tooltip: 'Layers & filters',
        icon: Badge(
          isLabelVisible: active,
          smallSize: 8,
          child: const Icon(Icons.layers_outlined),
        ),
        onPressed: onPressed,
      ),
    );
  }
}

/// Section header inside the Layers & Filters sheet.
class _SheetSectionLabel extends StatelessWidget {
  const _SheetSectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A draggable measure-tool endpoint. Bigger than the visible dot so the
/// touch target isn't fussy to grab in the field; [onDrag] receives each
/// pan's screen-pixel delta so the caller can reproject it through the live
/// map camera (zoom/rotation-aware) rather than this widget guessing at a
/// lat/lon delta itself.
/// The observer/vantage point a viewshed was computed from — so the user can
/// see which point the blue visibility overlay radiates out from.
class _ViewshedObserverMarker extends StatelessWidget {
  const _ViewshedObserverMarker({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 1.0),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: const Icon(Icons.visibility, size: 15, color: Colors.white),
      ),
    );
  }
}

/// The grab handle at a selected bearing's tip (task 11.131).
///
/// **Why it declares a long press of its own.** The map already binds
/// `onLongPress` to "Navigate here" for a free point. Declaring the long press
/// here too means this detector — the deeper one — wins the gesture arena, so
/// a hold on the handle drags the tip and does *not* also drop a free-point
/// selection over the top of it, while a hold anywhere else on the map behaves
/// exactly as it did before. Winning the arena is also what keeps the map from
/// panning under the finger during the drag.
///
/// A plain pan is accepted as well, for anyone who starts moving before the
/// long-press deadline; both feed the same radial update. Double-tap puts this
/// one bearing back to the default length.
/// The live "how long is this bearing now" pill shown during a tip drag.
///
/// It reports the **drawn radius from the measurement point**, in the same
/// "1.23 km" / "850 m" form [formatDistanceMeters] gives the measure tool, the
/// navigation panel and the compass — one distance format across the app.
///
/// **It deliberately does not say the animal was detectable at that range.**
/// Nothing about dragging a wedge out is a claim about detection: the wedge is
/// an angular uncertainty cone and the length is how far you have chosen to
/// draw it. Naming the radius is what keeps that honest — a number the person
/// chose, stated back to them — where a bare longer shape with no number
/// invites exactly the reading it must not carry.
class _BearingLengthReadout extends StatelessWidget {
  const _BearingLengthReadout({required this.rangeMeters});

  final double rangeMeters;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Text(
        'Drawn to ${formatDistanceMeters(rangeMeters)}',
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
    );
  }
}

class _BearingTipHandle extends StatefulWidget {
  const _BearingTipHandle({
    required this.color,
    required this.dragging,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onReset,
  });

  final Color color;
  final bool dragging;
  final VoidCallback onDragStart;

  /// The offset accumulated since the press began, not a per-frame delta —
  /// so the length is always computed from where the drag started rather than
  /// by adding up frames, which drifts.
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onReset;

  @override
  State<_BearingTipHandle> createState() => _BearingTipHandleState();
}

class _BearingTipHandleState extends State<_BearingTipHandle> {
  /// Accumulated for the pan path only; the long-press path reports its own
  /// offset from the press point.
  Offset _panAccumulated = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final size = widget.dragging ? 20.0 : 16.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) => widget.onDragStart(),
      onLongPressMoveUpdate: (d) => widget.onDragUpdate(d.offsetFromOrigin),
      onLongPressEnd: (_) => widget.onDragEnd(),
      onLongPressCancel: widget.onDragEnd,
      onPanStart: (_) {
        _panAccumulated = Offset.zero;
        widget.onDragStart();
      },
      onPanUpdate: (d) {
        _panAccumulated += d.delta;
        widget.onDragUpdate(_panAccumulated);
      },
      onPanEnd: (_) => widget.onDragEnd(),
      onPanCancel: widget.onDragEnd,
      onDoubleTap: widget.onReset,
      child: Center(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [
              BoxShadow(color: Colors.black38, blurRadius: 3),
            ],
          ),
        ),
      ),
    );
  }
}

class _MeasurePointHandle extends StatelessWidget {
  const _MeasurePointHandle({required this.onDrag});
  final ValueChanged<Offset> onDrag;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanUpdate: (details) => onDrag(details.delta),
      child: Center(
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context).colorScheme.onSurface,
            border: Border.all(color: Colors.white, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// Point-to-point measure tool result (design doc "Map Furniture": "distance
/// + bearing between two tapped points"). Shows a prompt while only one point
/// is placed, and the computed result once both are.
class _ComputationProgressBar extends StatelessWidget {
  const _ComputationProgressBar({super.key, required this.status});
  final ComputationRunning status;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(status.label, style: const TextStyle(fontSize: 11)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 100,
            child: LinearProgressIndicator(value: status.progress),
          ),
        ],
      ),
    );
  }
}

/// Shows a [ComputationFailed] status's message (task 11.87) — until now
/// the bottom column simply had nothing to show for this state, so a failed
/// viewshed/position-solve told nobody why. Dismissible: the state does not
/// clear itself (there is no "try again" to detect), so it would otherwise
/// sit here until the next computation starts.
class _ComputationFailedBar extends StatelessWidget {
  const _ComputationFailedBar({
    super.key,
    required this.status,
    required this.onDismiss,
  });
  final ComputationFailed status;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      color: colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              status.message,
              style: TextStyle(fontSize: 11, color: colorScheme.onErrorContainer),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: colorScheme.onErrorContainer),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: onDismiss,
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }
}

/// The person a truth point records as having found it (task 11.93), for the
/// info panel.
///
/// A one-row lookup rather than the bulk map the Log builds: the panel shows
/// one point at a time, and a project-wide user map would be loaded on every
/// map open to name a single person on a panel that is usually closed.
final _truthFinderProvider = FutureProvider.family<User?, String>((
  ref,
  userId,
) async {
  final repo = await ref.watch(userRepositoryProvider.future);
  return repo.findById(userId, includeDeleted: true);
});

/// Bottom info panel for the tapped recording. Bearings and truth points
/// show their details; a bearing offers Edit (the shared notes/signal/quality
/// dialog) — gated to the same combined role-and-author rule as the Log
/// screen, via [authorEditVerdict], so the two surfaces can't disagree about
/// the same observation (task 8.2, extended by task 11.12 to the role
/// gradient); an estimate offers a show/hide toggle for its
/// error ellipse (the contributing bearings are highlighted on the map while
/// it's selected) plus an "Edit in Estimator" jump to the tag-scoped Position
/// Estimation screen; a truth point shows its precision and what was found,
/// and offers Edit and Delete gated on [truthPointEditVerdict] (task 11.92).
class _SelectionInfoPanel extends StatelessWidget {
  const _SelectionInfoPanel({
    super.key,
    required this.selection,
    required this.currentUserId,
    required this.standing,
    required this.tagNames,
    required this.coordinateFormat,
    required this.showEllipse,
    required this.onToggleEllipse,
    required this.onClose,
    required this.onEditObservation,
    required this.onEditEstimate,
    required this.onEditTagLocation,
    required this.onDeleteTagLocation,
    required this.onNavigate,
    required this.onCopyForTriTrack,
  });

  final _MapSelection selection;

  /// The signed-in user, or null if identity hasn't resolved yet — passed
  /// through to [MutationRule.author.permits] rather than compared directly,
  /// so this stays in lockstep with the repository-layer check.
  final String? currentUserId;

  /// Whether the role gradient (task 11.3) permits a write in this project at
  /// all — the other half of [authorEditVerdict], alongside [currentUserId]'s
  /// authorship. A `viewer` editing their own pre-demotion observation must be
  /// refused here exactly as `BaseRepository._authorize` would refuse it.
  final ProjectStanding standing;
  final Map<String, _TagRow> tagNames;
  final CoordinateFormat coordinateFormat;
  final bool showEllipse;
  final ValueChanged<bool> onToggleEllipse;
  final VoidCallback onClose;
  final void Function(Observation observation) onEditObservation;
  final VoidCallback onEditEstimate;

  /// Task 11.92 — correcting and deleting a truth point from the panel that
  /// shows it. Before this the map could draw the point and offer nothing else.
  final void Function(ActualTagLocation location) onEditTagLocation;
  final void Function(ActualTagLocation location) onDeleteTagLocation;

  /// lat, lon, and a short label (null for a free-tapped point).
  final void Function(double lat, double lon, String? label) onNavigate;

  /// "Copy for TriTrack" — only ever called for a bearing
  /// ([_ObsSelection]); the parent owns the repository lookups
  /// ([ObservationShare.encode] needs the tag and observer rows, not just
  /// this panel's [tagNames] display map).
  final void Function(Observation observation) onCopyForTriTrack;

  String _tagLabel(String? tagId) {
    if (tagId == null) return 'No tag';
    final t = tagNames[tagId];
    if (t == null) return 'Unknown tag';
    return '${t.tagName} · ${t.frequencyMhz.toStringAsFixed(3)} MHz';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        // Task 11.133 item 1. Michael, 2026-09-02: "there is a lot of white
        // space in the box typically." Every pixel of it is a pixel the scale
        // bar, the coordinate readout, the map credit and the "+" button are
        // pushed up by, because task 11.126 lifts all of them by this card's
        // **measured** height each frame rather than by a constant. So the
        // card's padding is not cosmetic here — it is the bottom of the map.
        // Budgeted in `test/features/map/selection_card_height_test.dart`.
        padding: const EdgeInsets.fromLTRB(14, 6, 8, 8),
        // Every action button on all four cards, in one place (task 11.133
        // item 1), rather than a `style:` repeated eight times that a ninth
        // button would silently not get.
        //
        // Material 3's default button is 48 logical pixels tall because
        // `tapTargetSize` is `padded` — the label and its outline are about
        // 36, and the rest is invisible touch slack. Dropping that slack takes
        // 12 pixels off every row of buttons here, and the same 12 off the
        // bottom furniture above it.
        //
        // **36 is a judgement and it is the smallest number in this file that
        // is one.** Material's own guidance is 48. These are secondary actions
        // inside a card the person has just deliberately raised, each of which
        // is reversible or confirmed — Delete asks first, Edit opens a dialog,
        // Navigate is undone by stopping navigation — so a mis-tap costs a
        // tap. The close button next to them stays at 32 for the same reason.
        // If Michael finds these hard to hit in the field, this is the number
        // to raise, and `selection_card_height_test.dart` will say exactly
        // what raising it costs.
        child: OutlinedButtonTheme(
          data: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
          child: switch (selection) {
            _ObsSelection(:final observation) =>
              _observation(context, observation),
            _EstSelection(:final estimate) => _estimate(context, estimate),
            _TagLocSelection(:final location) => _tagLocation(context, location),
            _FreePointSelection(:final point) => _freePoint(context, point),
          },
        ),
      ),
    );
  }

  Widget _header(BuildContext context, String title, {Widget? shareButton}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          ),
        ),
        // Task 11.209: the share menu sits in this same row, beside the close
        // button rather than in a row of its own — the card's space budget
        // (`selection_card_height_test.dart`) is measured against this row's
        // height, and a second row would add a full row to all four cards.
        if (shareButton != null) ...[shareButton, const SizedBox(width: 4)],
        // 32x32 rather than Material's 48 (task 11.133 item 1). This row's
        // height is set by the close button and nothing else, so every pixel
        // here is a pixel off all four cards — and off the scale bar, the
        // coordinate readout, the map credit and the "+" button, which task
        // 11.126 lifts by the card's measured height.
        //
        // **`tapTargetSize` is the field that does the work, not
        // `constraints`.** Under Material 3 an `IconButton` is a
        // `ButtonStyleButton`, which sizes from its `ButtonStyle` and ignores
        // the `constraints`/`padding` arguments that worked under Material 2 —
        // so the obvious version of this change compiles, reads correctly and
        // saves nothing at all. It was measured, which is the only reason
        // anybody found out.
        //
        // **Deliberately not smaller than 32**: that is the floor for a
        // control somebody presses wearing field gloves. It is also not the
        // only way out of the card — tapping the map elsewhere clears the
        // selection too.
        IconButton(
          icon: const Icon(Icons.close, size: 20),
          tooltip: 'Close',
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            minimumSize: const Size(32, 32),
            padding: EdgeInsets.zero,
          ),
          onPressed: onClose,
        ),
      ],
    );
  }

  /// Task 11.209's share menu: "Copy coordinates", "Copy for TriTrack" (only
  /// where [onCopyForTriTrack] is given), "Share…" and "Open in Maps" — the
  /// same 32x32 footprint as the close button beside it, for the same reason
  /// (field gloves, and the card's measured space budget).
  Widget _shareMenuButton(
    BuildContext context, {
    required _ShareTarget target,
    VoidCallback? onCopyForTriTrack,
  }) {
    return SizedBox(
      width: 32,
      height: 32,
      child: PopupMenuButton<_ShareAction>(
        icon: const Icon(Icons.share_outlined, size: 20),
        tooltip: 'Share',
        padding: EdgeInsets.zero,
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: _ShareAction.copyCoordinates,
            child: Text('Copy coordinates'),
          ),
          if (onCopyForTriTrack != null)
            const PopupMenuItem(
              value: _ShareAction.copyForTriTrack,
              child: Text('Copy for TriTrack'),
            ),
          const PopupMenuItem(
            value: _ShareAction.share,
            child: Text('Share…'),
          ),
          const PopupMenuItem(
            value: _ShareAction.openInMaps,
            child: Text('Open in Maps'),
          ),
        ],
        onSelected: (action) {
          switch (action) {
            case _ShareAction.copyCoordinates:
              _copyCoordinates(context, target.latitude, target.longitude);
            case _ShareAction.copyForTriTrack:
              onCopyForTriTrack?.call();
            case _ShareAction.share:
              _shareViaSheet(context, target);
            case _ShareAction.openInMaps:
              _openInMaps(context, target.latitude, target.longitude, target.mapLabel);
          }
        },
      ),
    );
  }

  Future<void> _copyCoordinates(BuildContext context, double lat, double lon) async {
    final text = CoordinateFormatter.format(lat, lon, coordinateFormat);
    final copied = await runGuardedWrite(
      context,
      refused: null,
      write: () async => Clipboard.setData(ClipboardData(text: text)),
      failed: 'Could not copy these coordinates. Try again.',
    );
    if (!copied || !context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copied — paste into any app')));
  }

  /// The platform share sheet, offered the coordinate text and a GPX
  /// waypoint file — task 11.209. **A position estimate's uncertainty does
  /// not survive a map pin, so [_ShareTarget.detail] (the error ellipse, for
  /// an estimate) travels in both the shared text and the GPX `<desc>`.**
  Future<void> _shareViaSheet(BuildContext context, _ShareTarget target) async {
    final coordText = CoordinateFormatter.format(target.latitude, target.longitude, coordinateFormat);
    final shareText = [
      target.title,
      coordText,
      if (target.detail != null) target.detail!,
    ].join('\n');
    // Read before the first `await` — a `BuildContext` is not safe to touch
    // after one, and this card's render object does not change while the
    // menu it opened this dialog from is still open anyway.
    final box = context.findRenderObject() as RenderBox?;
    final sharePositionOrigin =
        box != null ? (box.localToGlobal(Offset.zero) & box.size) : null;
    await runGuardedWrite(
      context,
      refused: null,
      write: () async {
        final gpx = GpxWaypointWriter.build(
          latitude: target.latitude,
          longitude: target.longitude,
          name: target.title,
          elevationMeters: target.elevationMeters,
          description: target.detail,
          timeUtc: target.timeUtc,
        );
        final dir = await getTemporaryDirectory();
        final safeName = target.title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
        final file = File('${dir.path}/tritrack_$safeName.gpx');
        await file.writeAsString(gpx);
        await SharePlus.instance.share(
          ShareParams(
            text: shareText,
            files: [XFile(file.path)],
            sharePositionOrigin: sharePositionOrigin,
          ),
        );
      },
      failed: 'Could not open the share sheet. Try again.',
    );
  }

  /// Hands the coordinate to the platform's own maps app — task 11.209.
  /// **Says so when nothing answers**, the same rule `AttributionLink`
  /// follows for a dead browser link: a control that silently does nothing
  /// is not a way out of the card.
  Future<void> _openInMaps(
    BuildContext context,
    double lat,
    double lon,
    String? label,
  ) async {
    final uri = MapHandoff.uriFor(lat, lon, label: label, isAndroid: Platform.isAndroid);
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!context.mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('No maps app answered. The coordinates are still on the card above.'),
      ),
    );
  }

  Widget _observation(BuildContext context, Observation o) {
    final bearing = o.observationType == ObservationType.directional
        ? '${o.trueNorthBearing?.round()}°±${o.bearingUncertainty?.round() ?? '?'}°'
        : observationTypeLabel(o.observationType);
    final title = '${observationTypeLabel(o.observationType)} · ${_tagLabel(o.tagId)}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(
          context,
          title,
          shareButton: _shareMenuButton(
            context,
            target: _ShareTarget(
              title: title,
              latitude: o.latitude,
              longitude: o.longitude,
              elevationMeters: o.elevation,
              timeUtc: o.timestampUtc,
              detail:
                  '${o.timestampLocal.toString().substring(0, 16)} · $bearing',
              // Task 11.209 item 2: a bearing is not a point. The pin this
              // opens in the external maps app is the observer's own
              // position, not the animal's — say so, since a bare "Bearing"
              // label would read as the latter.
              mapLabel: "Bearing · observer's position",
            ),
            // A tagless note has no `Tag` for `ObservationShare.encode` to
            // take, so the entry is not offered rather than offered to fail.
            onCopyForTriTrack: o.tagId == null ? null : () => onCopyForTriTrack(o),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${o.timestampLocal.toString().substring(0, 16)} · $bearing',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                '${signalStrengthLabel(o.signalStrength)}'
                '${o.bearingQuality != null ? ' · ${bearingQualityLabel(o.bearingQuality!)}' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
              if (o.notes != null && o.notes!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(o.notes!, style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                ),
              const SizedBox(height: 8),
              Builder(builder: (context) {
                // Task 11.12: rendered disabled with a reason, not absent —
                // same "explain, don't just hide" rule as the Log/Team tabs'
                // Edit/Delete entries, which this is deliberately kept in
                // lockstep with via `authorEditVerdict`.
                //
                // Task 11.137: the reason was in a `Tooltip`, and a touchscreen
                // never shows one — so on the device this app is used on, Edit
                // greyed out with no explanation anywhere. It is a line under
                // the buttons now, and it takes no height at all while Edit is
                // available.
                final verdict = authorEditVerdict(
                  standing: standing,
                  actorUserId: currentUserId,
                  rowUserId: o.userId,
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.navigation, size: 16),
                          label: const Text('Navigate'),
                          onPressed: () => onNavigate(
                            o.latitude,
                            o.longitude,
                            'Bearing · ${o.timestampLocal.toString().substring(0, 16)}',
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.edit, size: 16),
                          label: const Text('Edit'),
                          onPressed:
                              verdict.canEdit ? () => onEditObservation(o) : null,
                        ),
                      ],
                    ),
                    DisabledReasonNote(
                      reason: verdict.canEdit ? null : verdict.reason,
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _estimate(BuildContext context, _EstimateRow e) {
    // **"No error ellipse" in words, not a dash** (task 11.323): a
    // two-bearing estimate has none, and the record says so.
    final ellipse = e.hasEllipse
        ? 'Error ellipse ${e.semiMajorAxis!.round()}×${e.semiMinorAxis!.round()} m'
        : 'No error ellipse';
    final title = 'Estimated position · ${_tagLabel(e.tagId)}';
    final detail =
        '$ellipse · ${e.bearingResolution.label('bearings used')}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(
          context,
          title,
          shareButton: _shareMenuButton(
            context,
            target: _ShareTarget(
              title: title,
              latitude: e.latitude,
              longitude: e.longitude,
              // Task 11.209 item 2: "a position estimate's uncertainty does
              // not survive a map pin" — the error ellipse travels in the
              // plain text and the GPX description instead.
              detail: detail,
              mapLabel: title,
            ),
            // No "Copy for TriTrack": an estimate is not an `Observations`
            // row and `ObservationShare.encode` has nothing to encode it as.
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${e.timestampLocal.toString().substring(0, 16)} · '
                '${CoordinateFormatter.format(e.latitude, e.longitude, coordinateFormat)}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(detail, style: const TextStyle(fontSize: 12)),
              // Task 11.336: by the stored list's length, not the
              // resolvable count `detail` prints — see `FewBearingsCaution`.
              if (FewBearingsCaution.applies(
                bearings: e.bearingResolution.totalCount,
                hasEllipse: e.hasEllipse,
              ))
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(
                    FewBearingsCaution.text,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Switch(
                          value: showEllipse,
                          onChanged: onToggleEllipse,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        const Flexible(
                          child: Text('Show error ellipse', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text('Edit in Estimator'),
                    onPressed: onEditEstimate,
                  ),
                ],
              ),
              // Task 11.185: the wedges of the bearings that produced this
              // estimate would otherwise sit on top of the ellipse at a
              // heavier alpha than the ellipse itself, burying it — so the
              // map hides those wedges (only those; other wedges on the map
              // are unaffected) whenever the ellipse is actually drawn here.
              // This is where the suppression is decided, not the
              // "Uncertainty wedges" layer toggle — that toggle still
              // governs every other wedge on the map and disabling it would
              // take away real control. The sentence explaining this to a
              // person moved to the legend card's footnote in task 11.206 —
              // this card explains an estimate somebody asked about, not why
              // the map draws what it draws.
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.navigation, size: 16),
                  label: const Text('Navigate'),
                  onPressed: () => onNavigate(e.latitude, e.longitude, 'Estimated position'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// A truth point: where somebody physically found the animal or the collar.
  ///
  /// **Precision and what-was-found are on the panel because without them the
  /// point does not mean anything** (task 11.92). A dot at a coordinate is not
  /// a truth point — a coordinate known to ±3 m with the animal in front of you
  /// and a coordinate known to ±40 m with a shed collar are different facts,
  /// and until this they rendered identically.
  Widget _tagLocation(BuildContext context, _TagLocationRow t) {
    final l = t.location;
    final verdict = truthPointEditVerdict(standing: standing);
    final scheme = Theme.of(context).colorScheme;
    final title = 'Truth point · ${_tagLabel(t.tagId)}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(
          context,
          title,
          shareButton: _shareMenuButton(
            context,
            target: _ShareTarget(
              title: title,
              latitude: l.latitude,
              longitude: l.longitude,
              timeUtc: l.timestampUtc,
              detail: '${truthFoundLabel(l.foundKind)} · '
                  'precision ±${_precisionLabel(l.uncertaintyRadius)} m',
              mapLabel: title,
            ),
            // No "Copy for TriTrack": a truth point is not an `Observations`
            // row either.
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 8, bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${l.timestampLocal.toString().substring(0, 16)} · '
                '${CoordinateFormatter.format(l.latitude, l.longitude, coordinateFormat)}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                '${truthFoundLabel(l.foundKind)} · '
                'precision ±${_precisionLabel(l.uncertaintyRadius)} m',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              // Task 11.93: who found it, and how the coordinate was got. Both
              // say "not recorded" rather than going blank on a point written
              // before schema v11 — the map is where somebody decides whether
              // to trust a dot, and a blank is a gap they fill in themselves.
              //
              // **One line rather than two** (task 11.133 item 1). This was
              // the tallest of the four cards by a wide margin, and it is the
              // one lifting the scale bar, the coordinate readout, the map
              // credit and the "+" button furthest up the screen. Both facts
              // are short, both are provenance, and neither wraps at phone
              // width — so the second line was carrying a separator's worth of
              // meaning for 18 pixels. **Nothing is dropped**: the same two
              // labels are shown, in the same words, joined by the same "·"
              // the lines above already use.
              if (l.userId == null)
                Text(
                  '${truthPositionSourceLabel(l.positionSource)} · '
                  '${truthFoundByLabel(l, null)}',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                )
              else
                Consumer(
                  builder: (context, ref, _) {
                    final finder = ref.watch(_truthFinderProvider(l.userId!));
                    return Text(
                      // Not `truthFoundByLabel(l, null)` while it loads — that
                      // would flash the raw id before the name arrives.
                      '${truthPositionSourceLabel(l.positionSource)} · '
                      '${finder.isLoading ? 'Found by: …' : truthFoundByLabel(l, finder.value)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
              if (l.notes != null && l.notes!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  l.notes!,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 6),
              // Task 11.102: three fixed-width buttons in a plain `Row` with
              // no `Expanded`/`Flexible` overflowed by a fraction of a pixel
              // on a real device ("RenderFlex overflowed by 0.0896 pixels on
              // the right") — a row that fits by nothing at all. `Wrap` gives
              // it real slack: on a device too narrow to fit all three, the
              // last button drops to a second line instead of clipping, and
              // nothing changes on a device wide enough to fit them (which is
              // every device this was actually tested against before now).
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Edit'),
                    onPressed: verdict.canEdit ? () => onEditTagLocation(l) : null,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Delete'),
                    onPressed: verdict.canEdit ? () => onDeleteTagLocation(l) : null,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.navigation, size: 16),
                    label: const Text('Navigate'),
                    onPressed: () => onNavigate(t.latitude, t.longitude, 'Truth point'),
                  ),
                ],
              ),
              // Task 11.137. Both editing buttons above share one verdict, so
              // the reason is said once under the row rather than twice inside
              // two tooltips a phone never opens.
              Align(
                alignment: Alignment.centerRight,
                child: DisabledReasonNote(
                  reason: verdict.canEdit ? null : verdict.reason,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// `12.0` → `12`, `12.5` → `12.5`, so a whole number of metres does not read
  /// as a false claim of decimal precision.
  static String _precisionLabel(double metres) {
    final text = metres.toString();
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  Widget _freePoint(BuildContext context, ll.LatLng point) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(
          context,
          'Map point',
          shareButton: _shareMenuButton(
            context,
            target: _ShareTarget(
              title: 'Map point',
              latitude: point.latitude,
              longitude: point.longitude,
              // No mapLabel: a free-tapped point is not a record, so there
              // is nothing to name it beyond its coordinates (task 11.209
              // item 2).
            ),
            // No "Copy for TriTrack": a free-tapped point is not a record at
            // all — there is no observation to encode.
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 8, bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                CoordinateFormatter.format(point.latitude, point.longitude, coordinateFormat),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.navigation, size: 16),
                  label: const Text('Navigate here'),
                  onPressed: () => onNavigate(point.latitude, point.longitude, null),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MapData {
  const _MapData({
    required this.observations,
    required this.estimates,
    required this.tagLocations,
    required this.nonDetections,
    required this.tags,
    required this.individuals,
    required this.deployments,
  });
  final List<Observation> observations;
  final List<_EstimateRow> estimates;
  final List<_TagLocationRow> tagLocations;
  final List<_NonDetectionRow> nonDetections;
  final List<_TagRow> tags;

  /// The project's live animals, by name (task 11.241).
  final List<_AnimalRow> individuals;

  /// The project's live links (task 11.247) — what the animal filter asks
  /// per ray, the same way the Log does:
  /// `DeploymentRepository.animalForObservationIn`. **Every** deployment, not
  /// only the current one, so a corrected date re-attributes exactly the
  /// window corrected rather than nothing.
  final List<Deployment> deployments;
}

class _NonDetectionRow {
  const _NonDetectionRow({
    required this.tagIds,
    required this.latitude,
    required this.longitude,
    required this.timestampUtc,
  });
  final List<String> tagIds;
  final double latitude;
  final double longitude;
  final DateTime timestampUtc;
}

class _EstimateRow {
  const _EstimateRow({
    required this.positionId,
    required this.tagId,
    required this.timestampLocal,
    required this.latitude,
    required this.longitude,
    required this.semiMajorAxis,
    required this.semiMinorAxis,
    required this.rotationAngle,
    required this.bearingResolution,
  });
  final String positionId;
  final String tagId;
  final DateTime timestampLocal;
  final double latitude;
  final double longitude;
  /// All three null when the estimate has no ellipse (task 11.323).
  final double? semiMajorAxis;
  final double? semiMinorAxis;
  final double? rotationAngle;

  /// Both axes measured — the condition every reader of the ellipse uses.
  bool get hasEllipse => semiMajorAxis != null && semiMinorAxis != null;

  /// Which of this estimate's stored `observation_ids_used` name a bearing
  /// this device actually holds — task 11.259. A carried-over season-clone
  /// estimate resolves none of them; see [EstimateBearingResolution].
  final EstimateBearingResolution bearingResolution;

  /// Only the ids that resolve locally — the set actually safe to highlight
  /// when this estimate is selected. Never the raw stored list: an id this
  /// device has no bearing for cannot be highlighted, and treating it as
  /// "something should light up" is the bug task 11.259 fixes.
  Set<String> get highlightableObservationIds => bearingResolution.resolvedIds;
}

/// A truth point on the map — where somebody physically found the animal, the
/// collar, or both.
///
/// Carries the whole [ActualTagLocation] rather than four unpacked columns
/// (task 11.92). The four were enough to draw a dot, and that was the defect:
/// the info panel could show position and time and had no way to show the
/// precision or what was found, **which are the two fields that decide what the
/// point means**. Unpacking a subset of a row into a private struct is how a
/// screen quietly loses the ability to say what it is showing.
class _TagLocationRow {
  const _TagLocationRow(this.location);
  final ActualTagLocation location;

  String get tagId => location.tagId;
  double get latitude => location.latitude;
  double get longitude => location.longitude;
  DateTime get timestampUtc => location.timestampUtc;
}

class _TagRow {
  const _TagRow(
    this.tagId,
    this.tagName,
    this.frequencyMhz,
    this.colorHex, {
    this.individualIds = const <String>{},
  });
  final String tagId;
  final String tagName;
  final double frequencyMhz;

  /// This collar's **most recent** deployment's animal's colour (or the
  /// neutral swatch on nobody) — `Tag.individualName`'s sibling column.
  /// Equipment identity, for the filter sheet's swatches; never used to
  /// draw a rendered element, which asks [DeploymentRepository
  /// .animalForObservationIn] at its own timestamp instead (task 11.248).
  final String colorHex;

  /// **Every animal that has worn this collar**, for the filter sheet's
  /// grouping (task 11.241, widened by 11.243). Empty for a collar nobody has
  /// linked — the normal starting state for a piece of equipment.
  ///
  /// A set rather than one id because the link is dated now: a collar
  /// refurbished onto a second animal has worn both, and it appears under
  /// both in the filter so that *"show me Marie"* still reaches the bearings
  /// taken while she was wearing it.
  final Set<String> individualIds;
}

/// **The legend row for a moment two deployments both cover** — design §4a,
/// task 11.251. `Contested: Kea or Marie`, the names sorted so the row is
/// stable whichever deployment a sync delivered first.
///
/// Shared by the legend and by the test that holds the wording, the way
/// `linkConfirmationText` is. The word comes first so the row cannot be read
/// as an animal called "Kea or Marie", and because on a one-line legend it
/// is the part that must survive being cut off.
String contestedLegendLabel(List<String> animalNames) =>
    'Contested: ${animalNames.join(' or ')}';

/// An animal in the filter sheet: id, name and colour, nothing else — the
/// sheet groups collars under it and toggles them together (task 11.241).
class _AnimalRow {
  const _AnimalRow(this.individualId, this.name, this.colorHex);
  final String individualId;
  final String name;
  final String colorHex;
}

class _AnimalGroup {
  const _AnimalGroup(this.animal, this.collars);
  final _AnimalRow animal;
  final List<_TagRow> collars;
}

/// Time filter for the map — hides recordings outside the chosen window so a
/// multi-day project's map doesn't turn into clutter.
enum _MapTimeWindow {
  all('All time'),
  today('Today'),
  yesterday('Yesterday'),
  last7('Last 7 days'),
  custom('Custom');

  const _MapTimeWindow(this.label);
  final String label;
}

/// A recording the user tapped on the map, surfaced in the bottom info panel.
sealed class _MapSelection {}

class _ObsSelection extends _MapSelection {
  _ObsSelection(this.observation);
  final Observation observation;
}

class _EstSelection extends _MapSelection {
  _EstSelection(this.estimate);
  final _EstimateRow estimate;
}

class _TagLocSelection extends _MapSelection {
  _TagLocSelection(this.location);
  final _TagLocationRow location;
}

/// A free-tapped (press-and-hold) map point with no associated recording —
/// shown in the same bottom info panel just as coordinates + a Navigate
/// action.
class _FreePointSelection extends _MapSelection {
  _FreePointSelection(this.point);
  final ll.LatLng point;
}

/// Task 11.209's share menu entries — one [PopupMenuButton] shared by all
/// four selection cards, with "Copy for TriTrack" present only where
/// [_SelectionInfoPanel._shareMenuButton] is given a callback for it.
enum _ShareAction { copyCoordinates, copyForTriTrack, share, openInMaps }

/// What "Share…" and "Open in Maps" need for one selection — gathered once
/// per card rather than threaded through as five separate parameters.
class _ShareTarget {
  const _ShareTarget({
    required this.title,
    required this.latitude,
    required this.longitude,
    this.elevationMeters,
    this.timeUtc,
    this.detail,
    this.mapLabel,
  });

  /// The GPX `<name>` and the share text's first line — the same title
  /// already shown in the card's header, so the shared text names the record
  /// the same way the card that offered it did.
  final String title;
  final double latitude;
  final double longitude;

  /// Only an observation carries this (task 11.209 item 2); null omits
  /// `<ele>` from the GPX rather than claiming an elevation of 0.
  final double? elevationMeters;

  /// Only included when it is a genuine UTC instant — an estimate's row
  /// carries local time alone, and a free-tapped point carries no time at
  /// all, so both leave this null rather than mislabeling local time as UTC.
  final DateTime? timeUtc;

  /// The one fact a map pin cannot carry — an estimate's error ellipse, most
  /// importantly (task 11.209 item 2: "a position estimate's uncertainty
  /// does not survive a map pin... the plain text and the GPX carry it").
  /// Travels in the shared text and the GPX `<desc>`; null for a free point.
  final String? detail;

  /// The label handed to the external maps app. **Null for a free point**
  /// (there is nothing to name); **explicitly says "observer's position"
  /// for a bearing** (task 11.209 item 2) rather than reusing [title], since
  /// a bearing's pin is not where the animal was.
  final String? mapLabel;
}

final _mapDataProvider = FutureProvider.family<_MapData, String>((
  ref,
  projectId,
) async {
  ref.watch(recordingsRevisionProvider);
  final obsRepo = await ref.watch(observationRepositoryProvider.future);
  final estRepo = await ref.watch(estimatedPositionRepositoryProvider.future);
  final locRepo = await ref.watch(actualTagLocationRepositoryProvider.future);
  final ndRepo = await ref.watch(nonDetectionRepositoryProvider.future);
  final tagRepo = await ref.watch(tagRepositoryProvider.future);

  final allObs = await obsRepo.findByProject(projectId);
  final directional = allObs
      .where(
        (o) =>
            o.observationType == ObservationType.directional &&
            o.trueNorthBearing != null,
      )
      .toList();
  // Cap to the most recent observations; real basemap pan/zoom means this is
  // just a sane default, not a schematic-plot workaround anymore.
  directional.sort((a, b) => b.timestampUtc.compareTo(a.timestampUtc));
  final recent = directional.take(50).toList();

  final estimates = await estRepo.findByProject(projectId);
  final locations = await locRepo.findByProject(projectId);
  final nonDetections = await ndRepo.findByProject(projectId);

  // One project-scoped read since task 11.219, where this was a
  // link-then-lookup: a tag belongs to this project, so the legend is
  // `WHERE project_id = ?` and nothing else.
  // Task 11.243: which animals each collar has worn, from the dated links.
  // **Every** deployment, not only the current one — filtering by Marie has
  // to reach bearings taken on a collar she has since stopped wearing, which
  // is the whole reason the link is dated.
  final deploymentRepo = await ref.watch(deploymentRepositoryProvider.future);
  final deployments = await deploymentRepo.findByProject(projectId);
  final wornBy = <String, Set<String>>{};
  for (final d in deployments) {
    (wornBy[d.tagId] ??= <String>{}).add(d.individualId);
  }
  final tags = [
    for (final tag in await tagRepo.findByProject(projectId))
      _TagRow(
        tag.tagId,
        tag.tagName,
        tag.frequencyMhz,
        tag.colorHex,
        individualIds: wornBy[tag.tagId] ?? const <String>{},
      ),
  ];
  // Task 11.241: the animals the filter sheet groups those collars under.
  final individualRepo = await ref.watch(individualRepositoryProvider.future);
  final individuals = [
    for (final a in await individualRepo.findByProject(projectId))
      _AnimalRow(a.individualId, a.name, a.colorHex),
  ];

  // Task 11.259: resolved against every bearing the project holds — not
  // `recent`'s 50-row cap — so an older, still-local bearing isn't mistaken
  // for one carried over from an earlier season.
  final allObsIds = {for (final o in allObs) o.observationId};
  return _MapData(
    observations: recent,
    estimates: [
      for (final e in estimates)
        _EstimateRow(
          positionId: e.positionId,
          tagId: e.tagId,
          timestampLocal: e.timestampLocal,
          latitude: e.latitude,
          longitude: e.longitude,
          semiMajorAxis: e.semiMajorAxis,
          semiMinorAxis: e.semiMinorAxis,
          rotationAngle: e.rotationAngle,
          bearingResolution: EstimateBearingResolution.of(
            e.observationIdsUsed,
            allObsIds,
          ),
        ),
    ],
    tagLocations: [
      for (final l in locations) _TagLocationRow(l),
    ],
    nonDetections: [
      for (final nd in nonDetections)
        _NonDetectionRow(
          tagIds: nd.tagIdsListenedFor,
          latitude: nd.latitude,
          longitude: nd.longitude,
          timestampUtc: nd.timestampUtc,
        ),
    ],
    deployments: deployments,
    tags: tags,
    individuals: individuals,
  );
});

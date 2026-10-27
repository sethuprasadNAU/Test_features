// **Every Map-tab picture is framed on the day's bearings, with the viewshed
// switched off** (`/w-30`).
//
// Michael, reading the guide, found bearings that "weren't really visible.
// They were behind some of the map display buttons." Three causes, all
// measured on the committed 6.1-inch pictures:
//
//  1. **The camera opens on the person's own position** (task 11.103's
//     chain: a device fix comes first), at about 200 m across. The day's
//     bearings are 1–2 km away, so they appeared only as fragments at the
//     edges — one under the layers button, one under the "+".
//  2. **The purple viewshed covered most of the map** and competed with the
//     bearings in every shot.
//  3. Nothing in the harness ever asked where the map's own furniture is, so
//     nothing could notice a bearing sitting under it.
//
// **The fix is measured framing, not a better guess at a zoom level.** The
// map already lays its bottom edge out against measured heights (task
// 11.126), and it keys each block of furniture, so this file reads the same
// keys off the live tree: the map-type switch at the top, the button column at
// the right, and the readout band, "+" column and whichever panel is up at the
// bottom. The camera is fitted to the bearings with padding taken from those
// rectangles, and then **every point that was meant to be visible is
// projected to the screen and checked against the same rectangles** — a
// framing that does not hold is a capture error, not a picture.
//
// **What "the day's bearings" means here:** the five bearings of Sage's
// morning session (`seed-session-morning`), the tag every Map-tab guide
// picture is about, each drawn at the app's default 400 m ray, plus the
// estimated position and the truth point they converge on. The other two tags'
// bearings are 2–3 km further out; fitting them too would shrink every ray to
// a few pixels, and the pictures would show more bearings and none of them
// legibly.
//
// **Which pictures keep the viewshed: none.** It is the subject of no picture
// the guide uses — its only mention on the site is one line in
// `docs/_index.md` — and in each of these it hides the thing the caption is
// about. If a page is ever written about the viewshed, it wants its own shot
// with its own framing rather than a share of one of these.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' as ll;

import 'harness.dart';
import 'readiness.dart';
import 'seed.dart';

/// The app's default ray length, in metres. `map_screen.dart` keeps this as a
/// private constant (`_defaultBearingRangeMeters`); a change there that this
/// file does not follow shows up as a framing error, because the tips it
/// projects would then be wrong by a visible amount.
const double _rayMeters = 400;

/// Breathing room between a point and the furniture it must clear, in logical
/// pixels.
const double _clearance = 16;

/// The rectangle of the map's own controls, in window coordinates.
class MapFurniture {
  MapFurniture({
    required this.pane,
    required this.top,
    required this.right,
    required this.bottom,
    required this.panelTop,
  });

  /// The whole `FlutterMap`.
  final Rect pane;

  /// Y of the lower edge of the map-type switch.
  final double top;

  /// X of the left edge of the button column.
  final double right;

  /// Y of the highest thing along the bottom edge.
  final double bottom;

  /// Y of the top of the selection card, or null when none is up.
  final double? panelTop;

  /// Where a point may sit and still be seen.
  Rect get clear => Rect.fromLTRB(
        pane.left + _clearance,
        top + _clearance,
        right - _clearance,
        bottom - _clearance,
      );

  @override
  String toString() => 'clear area ${clear.left.round()},${clear.top.round()} '
      '→ ${clear.right.round()},${clear.bottom.round()} '
      '(switch ends y=${top.round()}, buttons start x=${right.round()}, '
      'bottom furniture starts y=${bottom.round()}'
      '${panelTop == null ? '' : ', card starts y=${panelTop!.round()}'})';
}

/// Reads the map's furniture off the live tree.
///
/// Returns null, having recorded a capture error, when something that must be
/// there is not: a framing computed against furniture that could not be found
/// would be a guess wearing a measurement's name.
MapFurniture? measureMapFurniture(WidgetTester tester) {
  Rect? rectOf(Finder finder) {
    if (finder.evaluate().isEmpty) return null;
    final box = tester.renderObject(finder.first);
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  final pane = rectOf(find.byType(FlutterMap));
  final switchRect = rectOf(find.byWidgetPredicate(
      (w) => w.runtimeType.toString().startsWith('SegmentedToggle')));
  final buttons = rectOf(find.byKey(const ValueKey('map-right-controls')));
  final band = rectOf(find.byKey(const ValueKey('map-bottom-band')));
  final fab = rectOf(find.byKey(const ValueKey('map-record-fab')));
  final panels = rectOf(find.byKey(const ValueKey('map-bottom-panels')));

  final missing = <String>[
    if (pane == null) 'the map',
    if (switchRect == null) 'the map-type switch',
    if (buttons == null) 'the button column',
    if (band == null) 'the readout band',
    if (fab == null) 'the "+" column',
  ];
  if (missing.isNotEmpty) {
    recordCaptureError('cannot frame the map: ${missing.join(', ')} not found '
        'on screen, so there is nothing to measure the padding against');
    return null;
  }

  var bottom = math.min(band!.top, fab!.top);
  if (panels != null) bottom = math.min(bottom, panels.top);
  return MapFurniture(
    pane: pane!,
    top: switchRect!.bottom,
    right: buttons!.left,
    bottom: bottom,
    panelTop: panels?.top,
  );
}

/// One point that must be visible, with a name for the error message.
class _Wanted {
  const _Wanted(this.what, this.at);
  final String what;
  final ll.LatLng at;
}

/// Sage's morning bearings — origin and tip of each — plus the estimate and
/// the truth point. Read from the seed, so the framing follows the fixture.
List<_Wanted> _wantedPoints({bool truthPointOnly = false}) {
  const distance = ll.Distance();
  final wanted = <_Wanted>[];
  for (final o in seedObservations(const {})) {
    if (o.tagId != 'seed-tag-sage' || o.trueNorthBearing == null) continue;
    final origin = ll.LatLng(o.latitude, o.longitude);
    wanted.add(_Wanted('the origin of ${o.observationId}', origin));
    wanted.add(_Wanted('the tip of ${o.observationId}',
        distance.offset(origin, _rayMeters, o.trueNorthBearing!)));
  }
  final estimate = seedEstimate();
  wanted.add(_Wanted('the estimated position',
      ll.LatLng(estimate.latitude, estimate.longitude)));
  final truth = seedTruthPoint(const {});
  final truthWanted = _Wanted(
      'the truth point', ll.LatLng(truth.latitude, truth.longitude));
  wanted.add(truthWanted);
  // **The truth-point pictures are framed on the truth point and the estimate
  // it is being compared with, and nothing else.** The truth point is 100 m
  // from the estimate, and at the zoom that holds the day's bearings the two
  // markers are 13 logical points apart: the first run tapped the square and
  // opened the *estimate's* card, because the app's hit radius is 24 points.
  // A picture whose subject is a marker has to be at a zoom where a finger can
  // tell it from its neighbor.
  if (truthPointOnly) {
    return [
      _Wanted('the estimated position',
          ll.LatLng(estimate.latitude, estimate.longitude)),
      truthWanted,
    ];
  }
  return wanted;
}

MapController? _controller(WidgetTester tester) {
  final maps = find.byType(FlutterMap).evaluate();
  if (maps.isEmpty) return null;
  return (maps.first.widget as FlutterMap).mapController;
}

Future<void> _openLayersSheet(WidgetTester tester) async {
  final layers = find.byIcon(Icons.layers_outlined);
  if (layers.evaluate().isEmpty) {
    recordCaptureError('the Layers button is not on screen, so the viewshed '
        'switch could not be reached');
    return;
  }
  await tester.tap(layers.first);
  await settle(tester);
}

Future<void> _closeLayersSheet(WidgetTester tester) async {
  // **Popped, not tapped away.** Two taps were tried and both were wrong in
  // ways the pictures showed: one at the status-bar strip did not dismiss the
  // sheet at all, and one over the map landed *inside* the sheet — scrolling to
  // the Viewshed row lets the sheet grow to 92% of the screen — on the very
  // switch that had just been turned off, and turned it back on. The route's
  // own navigator is asked instead, which cannot land on anything.
  //
  // **Found by the sheet itself, not by its title.** The first version looked
  // for the text "Layers & Filters" — which is the first row of a lazy list and
  // is no longer in the tree once the list has been scrolled to the Viewshed
  // switch — so nothing was popped, the sheet stayed over the map, and the
  // next picture's tap on the truth-point marker landed inside it, on
  // "Observer height & opacity".
  final sheet = find.byType(DraggableScrollableSheet);
  if (sheet.evaluate().isNotEmpty) {
    Navigator.of(tester.element(sheet.first)).pop();
    await settle(tester);
  }
  if (find.byType(DraggableScrollableSheet).evaluate().isNotEmpty) {
    recordCaptureError('the Layers sheet is still open after it was closed');
  }
}

/// The Layers sheet's "Viewshed" switch, scrolled into view, or null when the
/// sheet has none.
///
/// **The sheet is a lazy `ListView`, and the switch is the seventh row**, so
/// at the sheet's opening height it has not been built at all — the second run
/// reported "no Viewshed switch" for a switch that was simply further down.
Future<SwitchListTile?> _viewshedRow(WidgetTester tester) async {
  final row = find.widgetWithText(SwitchListTile, 'Viewshed');
  final sheetScroll = find
      .descendant(
          of: find.byType(DraggableScrollableSheet),
          matching: find.byType(Scrollable))
      .first;
  if (row.evaluate().isEmpty) {
    try {
      await tester.scrollUntilVisible(row, 150,
          scrollable: sheetScroll, maxScrolls: 30);
    } catch (_) {
      // Reported just below, as a missing switch.
    }
  }
  if (row.evaluate().isEmpty) {
    recordCaptureError('the Layers sheet has no "Viewshed" switch, even '
        'scrolled to the end');
    return null;
  }
  await tester.ensureVisible(row.first);
  await settle(tester);
  return tester.widget<SwitchListTile>(row.first);
}

/// The map (by its `MapController`, which lives and dies with the screen's
/// `State`) whose viewshed this file has already computed-and-switched-off.
///
/// **The first version asked the Layers sheet instead** — switch off and
/// enabled meant "already off" — **and the first run showed why that is not
/// evidence.** The switch is enabled the moment a viewshed *result* exists,
/// and the app turns the layer *on* a moment after that, so a map that had
/// computed but not yet auto-enabled read as "already off", the wait was
/// skipped, and the overlay arrived behind the shutter: purple in five
/// pictures whose readiness said it was out. A widget's state read at one
/// instant is not a history; identity of the map this file handled is.
Object? _handledMap;

/// Switches the viewshed off through the app's own Layers sheet, the way a
/// person would, and checks that it went.
///
/// **The switch is below the fold of the sheet**, so it is scrolled to before
/// it is tapped; a tap on a row that is in the tree but off screen is a tap
/// on nothing, which is how the first run left the viewshed on.
Future<void> _switchViewshedOff(WidgetTester tester) async {
  await _openLayersSheet(tester);
  final finder = find.widgetWithText(SwitchListTile, 'Viewshed');
  final row = await _viewshedRow(tester);
  if (row != null && row.value) {
    // **The switch's own callback, not a tap.** Two runs tapped it, and the
    // second time the tap landed on the "Observer height & opacity" row next to
    // it — the sheet was still settling after the scroll — and a second sheet
    // opened over the map for every picture after. A callback cannot land on a
    // neighbor; the check below is what says it worked.
    row.onChanged?.call(false);
    await settle(tester);
    if (tester.widget<SwitchListTile>(finder.first).value) {
      recordCaptureError("switched the Layers sheet's Viewshed off and it is "
          'still on');
    }
  }
  await _closeLayersSheet(tester);
}

/// **Waits for the viewshed, switches it off, and frames the camera on the
/// day's bearings** — the whole of `/w-30`, in the order it has to happen.
///
/// Call this straight after `goTo(… '/map')`. [state] names the picture it is
/// for, and only appears in messages.
///
/// [reservePanelPx] is how much of the bottom edge a selection card will take
/// once one is up, for the pictures whose card does not exist yet when the
/// framing happens (the bearing shots, where the tap that opens the card needs
/// a frame to tap in). Measured by the caller from a real card, never a
/// constant. Null when a card is already up or none is coming.
Future<void> prepareMapShot(
  WidgetTester tester,
  ProviderContainer container,
  String state, {
  double? reservePanelPx,
  bool truthPointOnly = false,
}) async {
  // The map keeps its state across a tab change (`/w-14` found that out), so
  // a later Map-tab picture may be looking at a map already handled.
  final controller = _controller(tester);
  if (controller == null || !identical(controller, _handledMap)) {
    await awaitViewshedComputed(tester, container, state);
    await _switchViewshedOff(tester);
    _handledMap = controller;
  }
  await frameMapOnBearings(tester, state,
      reservePanelPx: reservePanelPx, truthPointOnly: truthPointOnly);
}

/// Fits the camera to the day's bearings, padded by the measured furniture,
/// then verifies every wanted point landed in the clear area.
///
/// Callable again after a card opens: the camera moves, the selection does
/// not.
Future<void> frameMapOnBearings(
  WidgetTester tester,
  String state, {
  double? reservePanelPx,
  bool moveCamera = true,
  bool truthPointOnly = false,
}) async {
  final controller = _controller(tester);
  final furniture = measureMapFurniture(tester);
  if (controller == null || furniture == null) {
    if (controller == null) {
      recordCaptureError('no map to frame for $state');
    }
    return;
  }

  // A card that is not up yet still takes the bottom edge in the picture.
  var clear = furniture.clear;
  if (reservePanelPx != null && furniture.panelTop == null) {
    // **The card lifts the readout band and the "+" by its own height plus 20**
    // (`_bottomFurnitureLift` in `map_screen.dart`), so the bottom of the clear
    // area with a card up is the furniture's resting top minus that lift, not
    // the card's top. `selectionCardHeight` already includes 12 of the 20.
    final reserved = furniture.bottom - (reservePanelPx + 8) - _clearance;
    if (reserved < clear.bottom) {
      clear = Rect.fromLTRB(clear.left, clear.top, clear.right, reserved);
    }
  }

  final wanted = _wantedPoints(truthPointOnly: truthPointOnly);
  final pane = furniture.pane;
  if (moveCamera) {
    controller.fitCamera(CameraFit.coordinates(
      coordinates: [for (final w in wanted) w.at],
      padding: EdgeInsets.fromLTRB(
        clear.left - pane.left,
        clear.top - pane.top,
        pane.right - clear.right,
        pane.bottom - clear.bottom,
      ),
      // A pair 100 m apart would otherwise fit at the maximum zoom; capped so
      // the map still shows the ground around them.
      maxZoom: truthPointOnly ? 15.5 : 16,
    ));
    await settle(tester, wait: const Duration(seconds: 1));
  }

  // **The check that makes this an instrument.** Each wanted point is
  // projected with the camera as it now stands and asked whether it is in the
  // clear area. Tolerance of one pixel, because the projection is a float.
  final camera = controller.camera;
  final misplaced = <String>[];
  for (final w in wanted) {
    final at = camera.latLngToScreenOffset(w.at) + pane.topLeft;
    if (!clear.inflate(1).contains(at)) {
      misplaced.add('${w.what} at ${at.dx.round()},${at.dy.round()}');
    }
  }
  // ignore: avoid_print
  print('SCREENSHOT HARNESS: $state ${moveCamera ? 'framed' : 'checked'} at zoom '
      '${camera.zoom.toStringAsFixed(2)}, ${furniture.toString()}'
      '${reservePanelPx == null ? '' : ' with ${reservePanelPx.round()}px '
          'reserved for a card'}; ${wanted.length - misplaced.length} of '
      '${wanted.length} wanted points clear');
  if (misplaced.isNotEmpty) {
    recordCaptureError('the camera could not put ${misplaced.length} wanted '
        'point(s) clear of the map controls — ${misplaced.join('; ')} — so '
        '$state is a picture with bearings behind the furniture (maxZoom or '
        'the padding is wrong)');
  }
}

/// **Waits until the map's camera has stopped moving** (`/w-32`, from task
/// 11.319).
///
/// After the Map tab opens with a GPS fix, the first frame is drawn at the
/// opening zoom and the camera then moves to the fix. A marker found and tapped
/// in that first frame is tapped where it *was*, so the tap lands beside the
/// marker or on a neighbor. The camera is asked rather than a time guessed:
/// four consecutive 250 ms looks at the same center, zoom and rotation count
/// as settled, and a camera that never settles is a capture error, not a tap
/// at whatever moment a ceiling ran out.
Future<void> awaitCameraSettled(
  WidgetTester tester,
  String state, {
  Duration ceiling = const Duration(seconds: 30),
}) async {
  final controller = _controller(tester);
  if (controller == null) {
    recordCaptureError('no map to wait on for $state');
    return;
  }
  final clock = Stopwatch()..start();
  MapCamera? last;
  var stillFor = 0;
  while (stillFor < 4 && clock.elapsed < ceiling) {
    await settle(tester, wait: const Duration(milliseconds: 250));
    final camera = controller.camera;
    final same = last != null &&
        camera.center == last.center &&
        camera.zoom == last.zoom &&
        camera.rotation == last.rotation;
    stillFor = same ? stillFor + 1 : 0;
    last = camera;
  }
  clock.stop();
  final seconds = (clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
  if (stillFor < 4) {
    recordCaptureError('the map camera was still moving after ${seconds}s, so '
        'a tap on a marker for $state would land where the marker was');
    return;
  }
  // ignore: avoid_print
  print('SCREENSHOT HARNESS: $state: map camera settled after ${seconds}s at '
      'zoom ${last!.zoom.toStringAsFixed(2)}');
}

/// Height of the selection card, in logical pixels, or null when none is up.
double? selectionCardHeight(WidgetTester tester) {
  final panels = find.byKey(const ValueKey('map-bottom-panels'));
  if (panels.evaluate().isEmpty) return null;
  final box = tester.renderObject(panels.first);
  return box is RenderBox && box.hasSize ? box.size.height + 12 : null;
}

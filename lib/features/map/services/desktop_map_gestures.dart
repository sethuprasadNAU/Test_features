import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// Whether map screens should use desktop interaction conventions (click-drag
/// to pan, trackpad two-finger scroll or pinch to zoom) rather than touch
/// conventions (one-finger drag to pan, two-finger drag/pinch to pan-and-zoom
/// together). macOS is the only desktop target so far (Phase 5);
/// Windows/Linux are included for whenever/if those builds happen too.
bool get isDesktopMapPlatform =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// The interaction flags every map screen should use.
///
/// On desktop this drops two flags:
///  * [InteractiveFlag.pinchMove] — flutter_map's gesture recognizer
///    otherwise treats a plain two-finger trackpad scroll (no pinching) as a
///    pan, which is exactly the behavior [DesktopTrackpadZoom] below
///    overrides to zoom instead — leaving `pinchMove` enabled would fight it.
///  * [InteractiveFlag.flingAnimation] — flutter_map applies this as a
///    momentum *pan* at the end of **any** gesture with enough release
///    velocity, gated only by this flag, not by `pinchMove`/`pinchZoom`.
///    Without disabling it too, releasing a fast two-finger scroll still
///    kicks off a pan-fling right after `DesktopTrackpadZoom` was zooming it
///    — the zoom "transitions to a pan moving the map," as reported. Desktop
///    drag/scroll conventions (Google Maps included) don't have this
///    momentum anyway, so it's off for click-drag too, not just scrolling.
///
/// Touch platforms are unaffected (all gestures, including fling, stay
/// enabled).
///
/// [doubleTapZoom] lets a screen opt out of flutter_map's default
/// double-tap-to-zoom too, for maps where a double-tap/double-click is
/// meant to place something rather than zoom (see
/// `record_position_preview_screen.dart`).
int mapInteractionFlags({bool doubleTapZoom = true}) {
  var flags = InteractiveFlag.all;
  if (isDesktopMapPlatform) {
    flags &= ~InteractiveFlag.pinchMove & ~InteractiveFlag.flingAnimation;
  }
  if (!doubleTapZoom) {
    flags &= ~InteractiveFlag.doubleTapZoom & ~InteractiveFlag.doubleTapDragZoom;
  }
  return flags;
}

/// Wraps a [FlutterMap] so a desktop trackpad's two-finger scroll zooms
/// instead of panning — the Google Maps convention this app's desktop build
/// should follow (click-drag pans; pinch or two-finger scroll zooms).
///
/// flutter_map has no flag for this. A trackpad's plain two-finger scroll and
/// its pinch gesture both arrive as the same event type
/// ([PointerPanZoomUpdateEvent]) from the engine — the only difference is
/// whether [PointerPanZoomUpdateEvent.scale] moves away from 1.0. flutter_map
/// itself only reads `scale` (for pinch-zoom) and the gesture's translation
/// (for pan, via the now-disabled `pinchMove` flag — see
/// [mapInteractionFlags]); it has no path that turns a scale-less scroll into
/// a zoom. This widget listens for that same event one level up and does
/// exactly that: a near-1.0 `scale` with nonzero vertical pan is a scroll, so
/// it's converted to a zoom around the cursor, using the same
/// velocity flutter_map's own scroll-wheel-zoom uses so the two feel
/// identical. Anything with `scale` off 1.0 by more than a hair is left
/// alone — that's a real pinch, and flutter_map's own pinch-zoom handling
/// (still enabled) already deals with it.
class DesktopTrackpadZoom extends StatelessWidget {
  const DesktopTrackpadZoom({
    super.key,
    required this.mapController,
    required this.child,
  });

  final MapController mapController;
  final Widget child;

  /// Matches [InteractionOptions.scrollWheelVelocity]'s default so trackpad
  /// scroll-to-zoom feels the same as an external mouse's wheel-to-zoom.
  static const _velocity = 0.005;

  /// How far `scale` may drift from 1.0 and still count as "just scrolling."
  static const _pinchScaleEpsilon = 0.003;

  @override
  Widget build(BuildContext context) {
    if (!isDesktopMapPlatform) return child;
    return Listener(
      onPointerPanZoomUpdate: (event) {
        if ((event.scale - 1.0).abs() > _pinchScaleEpsilon) return;
        if (event.panDelta.dy == 0) return;
        final camera = mapController.camera;
        final newZoom = camera.clampZoom(camera.zoom - event.panDelta.dy * _velocity);
        if (newZoom == camera.zoom) return;
        final newCenter = camera.focusedZoomCenter(event.localPosition, newZoom);
        mapController.move(newCenter, newZoom);
      },
      child: child,
    );
  }
}

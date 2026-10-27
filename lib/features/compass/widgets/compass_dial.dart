import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../localization/angles.dart';

/// The compass rose: tick marks/labels, the magnetic needle ("M", solid
/// triangle from center to rim), the true-north marker (a standalone
/// triangle sitting on the rim, labeled "TN" plus its degree offset so it's
/// never confused with the magnetic needle), an uncertainty wedge, an
/// in-progress range-sweep wedge, a center readout disc, and a level badge.
///
/// Per the 2026-07-17 "rotate like a real/iPhone compass" revision: the ring
/// (ticks + N/E/S/W/degree labels) rotates opposite the device's live
/// heading, so a fixed point at screen-top always represents wherever the
/// phone is currently pointing — the ring turns underneath it, not the other
/// way around. Everything drawn on the ring (the magnetic needle when
/// reviewing an old capture, the true-north tick) is therefore positioned by
/// its bearing *relative to the live heading*, not by its raw absolute
/// bearing.
///
/// ## Display quantities versus data — read this before adding an input
///
/// Since task 11.106 the ring is drawn at a *smoothed* copy of the live
/// heading, so this widget works in two different frames and the difference
/// matters:
///
/// * **Display quantities** describe where the dial is drawn *right now*.
///   There is exactly one of them — the smoothed heading, `displayedHeadingDeg`
///   below (and `displayedTrueHeadingDeg`, derived from it by adding
///   declination). [liveHeadingDeg]/[liveTrueHeadingDeg] are the raw sensor
///   samples those are smoothed from; **nothing is positioned from the raw
///   values directly.**
/// * **Data quantities** are world bearings that exist independently of how
///   the dial happens to be drawn: [capturedMagneticBearingDeg],
///   [navigationBearingDeg], the range-capture endpoints. These are the only
///   things drawn *relative to* a display quantity.
///
/// **A smoothed copy and a raw copy of the same quantity must never meet in
/// one subtraction.** That is the defect task 11.177 fixed: the compass
/// screen passed the raw live heading as the magnetic bearing while the ring
/// turned at the smoothed one, so `raw − smoothed` made the "live" needle
/// swing by up to ~10° in the direction of the turn and settle back
/// afterwards — which is exactly what Michael reported on 2026-09-06. The
/// live heading is a display quantity and now has no data input at all:
/// [capturedMagneticBearingDeg] is null unless a genuinely frozen capture is
/// being reviewed, and when it is null the needle sits at 0° by construction.
///
/// The declination arc between the top pointer and the true-north tick
/// (present 2026-07-17 through an earlier revision) was removed per explicit
/// user feedback — it read as visual clutter, not a useful signal.
///
/// Magnetic and true-north are both triangles (distinguished by shape/size)
/// but in two *different* reds — a strong red for magnetic, a visibly
/// lighter red for true-north — per the user's explicit request.
class CompassDial extends StatefulWidget {
  const CompassDial({
    super.key,
    this.capturedMagneticBearingDeg,
    this.trueBearingDeg,
    this.uncertaintyDeg,
    this.liveHeadingDeg,
    this.liveTrueHeadingDeg,
    this.inProgressRangeStartDeg,
    this.capturedRangeStartDeg,
    this.capturedRangeEndDeg,
    this.navigationBearingDeg,
    required this.isLevel,
    this.levelOffsetX = 0,
    this.levelOffsetY = 0,
    this.size = 280,
  });

  /// DATA. The frozen magnetic bearing of a capture being *reviewed*, and
  /// nothing else — pass null whenever the dial is showing the live heading.
  ///
  /// Null is not "no needle": with no captured bearing the needle shows the
  /// live heading, which is a display quantity, so it is pinned to the top of
  /// the dial and does not move. Passing the live heading in here instead is
  /// the task 11.177 defect (see the class doc) — it reintroduces a raw value
  /// into a subtraction against the smoothed ring.
  final double? capturedMagneticBearingDeg;

  /// True-north bearing (magnetic + declination), if declination is known.
  /// Only used for the center readout text now — ring geometry uses
  /// [liveTrueHeadingDeg] instead (see class doc).
  final double? trueBearingDeg;

  /// ± uncertainty (°); drives the wedge width and the readout text.
  final double? uncertaintyDeg;

  /// The raw live magnetic heading sample. Smoothed by [_CompassDialState]
  /// into the one display quantity everything else is drawn relative to; it
  /// is never used raw for geometry. Null while sensors haven't produced a
  /// reading yet (ring stays unrotated, and no needle is drawn).
  final double? liveHeadingDeg;

  /// The raw live true heading sample (live magnetic + declination). Read
  /// only to recover the declination offset, which is then applied to the
  /// *smoothed* heading to place the true-north tick and the navigation line
  /// — so those share the ring's frame instead of racing it.
  final double? liveTrueHeadingDeg;

  /// The absolute magnetic bearing where an in-progress range-capture sweep
  /// started (null when not mid-sweep). While non-null, a wedge is drawn
  /// live from this bearing to the current [liveHeadingDeg], growing/
  /// shrinking as the user rotates the phone, so the swept band is visible
  /// *before* "End" is tapped — not just after.
  final double? inProgressRangeStartDeg;

  /// The final captured range-capture bearings (magnetic start/end),
  /// persisted after "End" is tapped — unlike [inProgressRangeStartDeg]
  /// (which tracks the live heading during the sweep and goes away once
  /// capture finishes), these stay fixed so the highlighted band from the
  /// scan remains visible on the dial alongside the center bearing needle.
  /// Both must be non-null to draw the band.
  final double? capturedRangeStartDeg;
  final double? capturedRangeEndDeg;

  /// TRUE bearing to the active navigation target, if one is set and GPS is
  /// available — see [NavigationTarget]/`navigationTargetProvider`. Same
  /// frame as [trueBearingDeg]/[liveTrueHeadingDeg].
  final double? navigationBearingDeg;

  final bool isLevel;

  /// Horizontal components of the device's "up" direction (~-1..1), used to
  /// move the level badge's dot like a real bubble level rather than just
  /// recoloring a static dot.
  final double levelOffsetX;
  final double levelOffsetY;

  final double size;

  /// Keys for the dial's painted layers, so a test can read the angle each
  /// marker was actually drawn at rather than inspecting pixels.
  static const ringKey = ValueKey('compass-dial-ring');
  static const needleKey = ValueKey('compass-dial-needle');
  static const uncertaintyWedgeKey = ValueKey('compass-dial-uncertainty-wedge');
  static const trueNorthKey = ValueKey('compass-dial-true-north');
  static const navigationLineKey = ValueKey('compass-dial-navigation-line');
  static const inProgressRangeSweepKey = ValueKey('compass-dial-in-progress-range-sweep');
  static const capturedRangeSweepKey = ValueKey('compass-dial-captured-range-sweep');

  @override
  State<CompassDial> createState() => _CompassDialState();
}

/// Smooths [CompassDial.liveHeadingDeg] between raw sensor samples before it
/// drives the ring's rotation.
///
/// `flutter_compass`/`sensors_plus` request roughly the same ~30 Hz sample
/// rate on both platforms (Android: `SENSOR_DELAY_MICROS = 30_000`; iOS:
/// `deviceMotionUpdateInterval = 1/30`), and this widget previously just
/// repainted on every raw sample with no interpolation at all — the ring
/// jumped straight to each new heading rather than easing toward it. Michael
/// reported the ring's motion as visibly choppier on a Samsung phone than on
/// iOS; since the requested rates match, the more likely explanation is that
/// iOS's `CLLocationManager` heading applies its own internal smoothing
/// before delivery while Android's raw `SensorManager` orientation does not,
/// which this repaint-per-sample code would expose directly on Android and
/// hide on iOS. **This could not be confirmed by measuring the actual
/// delivery rate on real Android hardware** — no Android device or working
/// emulator sensor feed was available to this change; see the task report.
///
/// The fix: ease the displayed heading toward each new raw sample over
/// [_smoothDuration] using the display's own frame ticker, rather than only
/// redrawing when a sample arrives. This is purely a rendering interpolation
/// — it never changes the value read for a captured bearing, which comes
/// from `compassControllerProvider.magneticHeadingDeg` directly (see
/// `bearing_capture_provider.dart`), not from anything in this widget.
/// [_smoothDuration] is kept short (one sample interval) so the ring still
/// tracks a fast turn closely — smoothing costs at most one sample's worth
/// of lag, traded for not jumping discretely between samples.
class _CompassDialState extends State<CompassDial> with SingleTickerProviderStateMixin {
  static const _smoothDuration = Duration(milliseconds: 100);

  late final AnimationController _controller;
  double? _displayedHeadingDeg;
  double _animStartDeg = 0;
  double _animTargetDeg = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _smoothDuration);
    _displayedHeadingDeg = widget.liveHeadingDeg;
  }

  @override
  void didUpdateWidget(covariant CompassDial old) {
    super.didUpdateWidget(old);
    final target = widget.liveHeadingDeg;
    if (target == null) {
      _controller.stop();
      _displayedHeadingDeg = null;
      return;
    }
    if (old.liveHeadingDeg == null || _displayedHeadingDeg == null) {
      // First reading (or recovering from unavailable) — snap rather than
      // animating in from nothing. `reset()` as well as `stop()`, so the
      // controller reads as dismissed and `_currentDisplayedDeg` falls back
      // to this snapped value rather than an expired animation's endpoints.
      _controller
        ..stop()
        ..reset();
      _displayedHeadingDeg = target;
      return;
    }
    final current = _currentDisplayedDeg();
    if (target == old.liveHeadingDeg) return;
    _animStartDeg = current;
    _animTargetDeg = current + Angles.shortestDifferenceDegrees(current, target);
    _controller
      ..stop()
      ..reset()
      ..forward();
  }

  double _currentDisplayedDeg() {
    // Keyed on the controller's *status*, not on `isAnimating`. A completed
    // controller is not animating but its value is exactly 1.0, and reading
    // the interpolation there is what makes the smoothed copy actually reach
    // the sample it was easing toward. Falling back to the stored value in
    // that case instead left a permanent residual — measured at 7.5° after a
    // 90° turn — because `didUpdateWidget` returns early once the heading
    // stops changing, so nothing ever closed the gap.
    if (_controller.status == AnimationStatus.dismissed) {
      return _displayedHeadingDeg ?? widget.liveHeadingDeg ?? 0.0;
    }
    final t = Curves.linear.transform(_controller.value);
    return Angles.normalizeDegrees(_animStartDeg + (_animTargetDeg - _animStartDeg) * t);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        _displayedHeadingDeg = widget.liveHeadingDeg == null ? null : _currentDisplayedDeg();
        return _buildDial(context);
      },
    );
  }

  Widget _buildDial(BuildContext context) {
    final capturedMagneticBearingDeg = widget.capturedMagneticBearingDeg;
    final trueBearingDeg = widget.trueBearingDeg;
    final uncertaintyDeg = widget.uncertaintyDeg;
    final liveTrueHeadingDeg = widget.liveTrueHeadingDeg;
    final inProgressRangeStartDeg = widget.inProgressRangeStartDeg;
    final capturedRangeStartDeg = widget.capturedRangeStartDeg;
    final capturedRangeEndDeg = widget.capturedRangeEndDeg;
    final navigationBearingDeg = widget.navigationBearingDeg;
    final isLevel = widget.isLevel;
    final levelOffsetX = widget.levelOffsetX;
    final levelOffsetY = widget.levelOffsetY;
    final size = widget.size;

    final colors = Theme.of(context).extension<TriTrackColors>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // ---- THE ONE DISPLAY FRAME -----------------------------------------
    // The smoothed heading. Everything below is drawn relative to this and
    // nothing below reads `widget.liveHeadingDeg` for geometry. Capture still
    // reads the raw provider value directly (see this class's doc comment) —
    // that is a data path and does not come through here.
    final displayedHeadingDeg = _displayedHeadingDeg;
    final ringRotationDeg = displayedHeadingDeg ?? 0.0;

    // Declination recovered from the raw pair, then re-applied to the
    // smoothed heading. Taking the difference of two raw samples is safe —
    // they are the same sample — and it is the only way to get a true heading
    // that is in the ring's frame rather than one sample ahead of it.
    final rawLiveHeadingDeg = widget.liveHeadingDeg;
    final declinationDeg = (rawLiveHeadingDeg == null || liveTrueHeadingDeg == null)
        ? null
        : Angles.shortestDifferenceDegrees(rawLiveHeadingDeg, liveTrueHeadingDeg);
    final displayedTrueHeadingDeg = (displayedHeadingDeg == null || declinationDeg == null)
        ? null
        : Angles.normalizeDegrees(displayedHeadingDeg + declinationDeg);

    // ---- MARKERS, each with the frame it lives in ------------------------

    // The magnetic needle. Reviewing a capture: a data bearing against the
    // display frame, so it swings as the phone turns away from it — which is
    // the point. Showing the live heading: a display quantity against itself,
    // which is 0 by construction and therefore pinned to the top of the dial
    // like a real compass. It is written as a literal 0 rather than computed
    // so that no future edit can reintroduce a raw-versus-smoothed subtraction
    // here (task 11.177).
    final double? needleRelativeDeg;
    if (capturedMagneticBearingDeg != null) {
      needleRelativeDeg = Angles.shortestDifferenceDegrees(
          ringRotationDeg, capturedMagneticBearingDeg);
    } else {
      needleRelativeDeg = displayedHeadingDeg == null ? null : 0.0;
    }

    // True north: a fixed point in the world, so it swings around the dial as
    // the phone turns — but against the *smoothed* true heading, so it keeps
    // a constant offset from the ring's own N label instead of racing it. Off
    // the raw sample this drifted up to 20.5° from the ring mid-turn.
    final trueNorthRelativeDeg = displayedTrueHeadingDeg == null
        ? null
        : Angles.shortestDifferenceDegrees(displayedTrueHeadingDeg, 0);

    // The navigation line: a data bearing (true frame) against the smoothed
    // true heading — same pattern as [trueNorthRelativeDeg], generalized from
    // a fixed target of 0 to an arbitrary true bearing. Same raw-sample drift
    // before this change, and equally invisible, because the line is supposed
    // to move.
    final navRelativeDeg = (navigationBearingDeg == null || displayedTrueHeadingDeg == null)
        ? null
        : Angles.shortestDifferenceDegrees(displayedTrueHeadingDeg, navigationBearingDeg);

    // Live in-progress range sweep: a frozen data start plus the display
    // heading as the moving edge. Both are expressed against the same
    // `ringRotationDeg`, so the wedge's leading edge lands exactly on the top
    // of the dial where the needle is. Already correct before task 11.177 —
    // it was reading the smoothed value all along — and it stays correct only
    // because the moving edge is `displayedHeadingDeg`, not the raw sample.
    // Known limit, unchanged: `shortestDifferenceDegrees` is signed and caps
    // at ±180°, so a sweep past half a turn renders as the short way round.
    final rangeSweepStartRelativeDeg = inProgressRangeStartDeg == null || displayedHeadingDeg == null
        ? null
        : Angles.shortestDifferenceDegrees(ringRotationDeg, inProgressRangeStartDeg);
    final rangeSweepDeg = inProgressRangeStartDeg == null || displayedHeadingDeg == null
        ? null
        : Angles.shortestDifferenceDegrees(inProgressRangeStartDeg, displayedHeadingDeg);

    // Captured (finished) range-capture band: two data bearings. The start is
    // placed against the display frame and the sweep is data-minus-data, so
    // no raw value is involved on either side — correct before task 11.177
    // and untouched by it.
    final capturedRangeStartRelativeDeg =
        capturedRangeStartDeg == null || capturedRangeEndDeg == null
            ? null
            : Angles.shortestDifferenceDegrees(ringRotationDeg, capturedRangeStartDeg);
    final capturedRangeSweepDeg = capturedRangeStartDeg == null || capturedRangeEndDeg == null
        ? null
        : Angles.shortestDifferenceDegrees(capturedRangeStartDeg, capturedRangeEndDeg);

    return SizedBox(
      width: size + 50,
      height: size + 50,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              key: CompassDial.ringKey,
              painter: _DialBackgroundPainter(isDark: isDark, ringRotationDeg: ringRotationDeg),
            ),
          ),
          if (rangeSweepStartRelativeDeg != null && rangeSweepDeg != null)
            SizedBox(
              width: size,
              height: size,
              child: CustomPaint(
                key: CompassDial.inProgressRangeSweepKey,
                painter: _RangeSweepPainter(
                  startRelativeDeg: rangeSweepStartRelativeDeg,
                  sweepDeg: rangeSweepDeg,
                  color: colors.bearingRay,
                ),
              ),
            ),
          if (capturedRangeStartRelativeDeg != null && capturedRangeSweepDeg != null)
            SizedBox(
              width: size,
              height: size,
              child: CustomPaint(
                key: CompassDial.capturedRangeSweepKey,
                painter: _RangeSweepPainter(
                  startRelativeDeg: capturedRangeStartRelativeDeg,
                  sweepDeg: capturedRangeSweepDeg,
                  color: colors.bearingRay,
                ),
              ),
            ),
          if (needleRelativeDeg != null && uncertaintyDeg != null)
            SizedBox(
              width: size,
              height: size,
              child: CustomPaint(
                key: CompassDial.uncertaintyWedgeKey,
                // Centred on the needle, so it inherits the needle's frame
                // exactly — including the task 11.177 defect, before the fix.
                painter: _WedgePainter(
                  centerDeg: needleRelativeDeg,
                  halfWidthDeg: uncertaintyDeg,
                  color: colors.bearingRay,
                ),
              ),
            ),
          if (trueNorthRelativeDeg != null)
            SizedBox(
              width: size,
              height: size,
              child: CustomPaint(
                key: CompassDial.trueNorthKey,
                painter: _TrueNorthMarkerPainter(
                  bearingDeg: trueNorthRelativeDeg,
                  color: colors.compassTrueNorth,
                ),
              ),
            ),
          if (needleRelativeDeg != null)
            SizedBox(
              width: size,
              height: size,
              child: CustomPaint(
                key: CompassDial.needleKey,
                painter: _NeedlePainter(
                  bearingDeg: needleRelativeDeg,
                  color: colors.compassMagneticNeedle,
                ),
              ),
            ),
          if (navRelativeDeg != null)
            SizedBox(
              width: size,
              height: size,
              child: CustomPaint(
                key: CompassDial.navigationLineKey,
                painter: _NavigationLinePainter(
                  bearingDeg: navRelativeDeg,
                  color: colors.navigationLine,
                ),
              ),
            ),
          // Text, not geometry: no subtraction, so the raw sample is the
          // right thing to show — it is the number a capture would record.
          _ReadoutDisc(
            magneticBearingDeg: capturedMagneticBearingDeg ?? rawLiveHeadingDeg,
            trueBearingDeg: trueBearingDeg,
            uncertaintyDeg: uncertaintyDeg,
          ),
          Positioned(
            top: 0,
            right: 0,
            child: _LevelBadge(
              isLevel: isLevel,
              offsetX: levelOffsetX,
              offsetY: levelOffsetY,
            ),
          ),
        ],
      ),
    );
  }
}

/// Circle border, tick marks (minor every 10°, major every 30°), and degree
/// labels every 15° (cardinals shown as N/E/S/W letters instead) — all
/// rotated by [ringRotationDeg] (the smoothed live heading — the dial's one
/// display quantity) so the ring turns like a real compass rose while the
/// rest of the dial's markers stay ring-relative.
class _DialBackgroundPainter extends CustomPainter {
  _DialBackgroundPainter({required this.isDark, required this.ringRotationDeg});

  final bool isDark;
  final double ringRotationDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final borderColor = isDark ? const Color(0xFFF2F2F0) : const Color(0xFF1A1A1A);
    final tickColor = isDark ? const Color(0xFFF2F2F0) : const Color(0xFF1A1A1A);
    final labelColor = isDark ? const Color(0xFF6C6C68) : const Color(0xFFA3A39F);
    final bg = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFFAFAF9);

    canvas.drawCircle(center, radius, Paint()..color = bg);
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Tick marks: minor every 10° (short), major every 30° (long).
    for (var deg = 0; deg < 360; deg += 10) {
      final isMajor = deg % 30 == 0;
      final outer = radius * 0.96;
      final inner = radius * (isMajor ? 0.82 : 0.88);
      final angle = _toCanvasAngle(Angles.shortestDifferenceDegrees(ringRotationDeg, deg.toDouble()));
      final p1 = center + Offset(math.cos(angle), math.sin(angle)) * outer;
      final p2 = center + Offset(math.cos(angle), math.sin(angle)) * inner;
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = tickColor.withValues(alpha: isMajor ? 1.0 : 0.35)
          ..strokeWidth = isMajor ? 1.5 : 1.0,
      );
    }

    // Degree labels every 15°; cardinals get letters instead of numbers.
    // Placed outside the tick band (ticks run up to radius*0.96) rather than
    // inside it, so labels don't visually collide with the tick marks.
    const cardinals = {0: 'N', 90: 'E', 180: 'S', 270: 'W'};
    for (var deg = 0; deg < 360; deg += 15) {
      final label = cardinals[deg];
      final angle = _toCanvasAngle(Angles.shortestDifferenceDegrees(ringRotationDeg, deg.toDouble()));
      final labelRadius = radius * (label != null ? 1.09 : 1.05);
      final pos = center + Offset(math.cos(angle), math.sin(angle)) * labelRadius;
      final tp = TextPainter(
        text: TextSpan(
          text: label ?? deg.toString(),
          style: TextStyle(
            color: label != null
                ? (isDark ? const Color(0xFFF2F2F0) : const Color(0xFF1A1A1A))
                : labelColor,
            fontSize: label != null ? 13 : (deg % 30 == 0 ? 9 : 8),
            fontWeight: label != null ? FontWeight.w800 : FontWeight.w400,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _DialBackgroundPainter oldDelegate) =>
      oldDelegate.isDark != isDark || oldDelegate.ringRotationDeg != ringRotationDeg;
}

/// Compass bearing (0°=N, CW) → canvas angle (radians, 0=+x/right, CW),
/// matching Flutter's y-down canvas convention (screen "up" = north = -π/2).
double _toCanvasAngle(double bearingDeg) =>
    (bearingDeg - 90) * math.pi / 180.0;

/// Magnetic-heading marker: a full needle from the center out to the rim,
/// solid-filled — the dominant indicator on the dial.
class _NeedlePainter extends CustomPainter {
  _NeedlePainter({required this.bearingDeg, required this.color});

  final double bearingDeg;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final angle = _toCanvasAngle(bearingDeg);
    final tip = center + Offset(math.cos(angle), math.sin(angle)) * radius * 0.80;
    final baseWidth = radius * 0.09;
    final perp = Offset(-math.sin(angle), math.cos(angle)) * baseWidth;

    final path = Path()
      ..moveTo(center.dx + perp.dx, center.dy + perp.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(center.dx - perp.dx, center.dy - perp.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawCircle(center, radius * 0.06, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _NeedlePainter oldDelegate) =>
      oldDelegate.bearingDeg != bearingDeg || oldDelegate.color != color;
}

/// Navigation-target marker: a thin blue line from center to near the rim
/// with a small open arrowhead at the tip — deliberately a *line*, not a
/// solid filled triangle like [_NeedlePainter] (the magnetic needle) or the
/// rim-only [_TrueNorthMarkerPainter] triangle, so it reads unambiguously as
/// "this direction points at your target" rather than being mistaken for
/// either existing marker. [bearingDeg] is already ring-relative (relative
/// to the live true heading — see [CompassDial.navigationBearingDeg]).
class _NavigationLinePainter extends CustomPainter {
  _NavigationLinePainter({required this.bearingDeg, required this.color});

  final double bearingDeg;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final angle = _toCanvasAngle(bearingDeg);
    final dir = Offset(math.cos(angle), math.sin(angle));

    final tip = center + dir * radius * 0.90;

    canvas.drawLine(
      center,
      tip,
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );

    // Small open arrowhead at the tip (two short strokes back from the tip),
    // rather than a filled shape, to keep this visually distinct from the
    // solid needle/triangle markers.
    const arrowLength = 10.0;
    const arrowSpreadDeg = 28.0;
    final back = -dir * arrowLength;
    final spread = arrowSpreadDeg * math.pi / 180.0;
    Offset rotate(Offset v, double a) => Offset(
          v.dx * math.cos(a) - v.dy * math.sin(a),
          v.dx * math.sin(a) + v.dy * math.cos(a),
        );
    final arrowPaint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(tip, tip + rotate(back, spread), arrowPaint);
    canvas.drawLine(tip, tip + rotate(back, -spread), arrowPaint);

    // Small dot at center so the line's origin is anchored/visible alongside
    // the needle's own center dot.
    canvas.drawCircle(center, radius * 0.03, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _NavigationLinePainter oldDelegate) =>
      oldDelegate.bearingDeg != bearingDeg || oldDelegate.color != color;
}

/// True-north marker: a standalone triangle sitting on the rim (not a full
/// needle from center) plus its degree offset from the current heading, like
/// the iPhone Compass app's true-north tick (e.g. "51") — distinguished from
/// the magnetic needle by both shape and its lighter red. [bearingDeg] is
/// already ring-relative (0 = current heading/top).
class _TrueNorthMarkerPainter extends CustomPainter {
  _TrueNorthMarkerPainter({required this.bearingDeg, required this.color});

  final double bearingDeg;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final angle = _toCanvasAngle(bearingDeg);
    final dir = Offset(math.cos(angle), math.sin(angle));
    final perp = Offset(-math.sin(angle), math.cos(angle));

    final tip = center + dir * radius * 0.94;
    final baseCenter = center + dir * radius * 0.80;
    final baseHalfWidth = radius * 0.055;

    final path = Path()
      ..moveTo(baseCenter.dx + perp.dx * baseHalfWidth, baseCenter.dy + perp.dy * baseHalfWidth)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(baseCenter.dx - perp.dx * baseHalfWidth, baseCenter.dy - perp.dy * baseHalfWidth)
      ..close();
    canvas.drawPath(path, Paint()..color = color);

    // "TN {degrees}" rather than a bare number — unlike the magnetic needle
    // (which reaches all the way to center and is always labeled "M"), this
    // rim-only triangle was ambiguous with just a numeral.
    final labelPos = center + dir * radius * 0.68;
    _paintLabel(canvas, 'TN ${bearingDeg.round().abs()}°', labelPos, color);
  }

  @override
  bool shouldRepaint(covariant _TrueNorthMarkerPainter oldDelegate) =>
      oldDelegate.bearingDeg != bearingDeg || oldDelegate.color != color;
}

/// Live in-progress range-capture sweep: a filled wedge from the bearing
/// where the sweep started to wherever the phone is pointing right now,
/// growing/shrinking in real time as the user rotates — so the highlighted
/// band is visible *during* the sweep, not only after "End" is tapped (at
/// which point the normal captured-bearing [_WedgePainter] takes over,
/// centered on the resolved midpoint).
class _RangeSweepPainter extends CustomPainter {
  _RangeSweepPainter({
    required this.startRelativeDeg,
    required this.sweepDeg,
    required this.color,
  });

  final double startRelativeDeg;
  final double sweepDeg;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (sweepDeg == 0) return;
    final center = size.center(Offset.zero);
    // Draw the band as an annular sector out near the rim, NOT a pie slice from
    // the center — the center is covered by the opaque readout disc (112px), so
    // a center-anchored wedge would be almost entirely hidden. Inner radius is
    // kept clear of that disc (radius ~56px) so the swept band is always
    // visible on the dial face.
    final outerRadius = size.width * 0.46;
    final innerRadius = math.max(size.width * 0.30, 62.0);
    final startAngle = _toCanvasAngle(startRelativeDeg);
    final sweep = sweepDeg * math.pi / 180.0;
    final outerRect = Rect.fromCircle(center: center, radius: outerRadius);
    final innerRect = Rect.fromCircle(center: center, radius: innerRadius);

    final path = Path()
      ..arcTo(outerRect, startAngle, sweep, true)
      ..arcTo(innerRect, startAngle + sweep, -sweep, false)
      ..close();

    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.42)..style = PaintingStyle.fill);
    // Outline so the swept/captured band reads clearly against the dial.
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
  }

  @override
  bool shouldRepaint(covariant _RangeSweepPainter oldDelegate) =>
      oldDelegate.startRelativeDeg != startRelativeDeg ||
      oldDelegate.sweepDeg != sweepDeg ||
      oldDelegate.color != color;
}

void _paintLabel(Canvas canvas, String text, Offset pos, Color color) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
}

/// Shaded uncertainty wedge (translucent), centered on the captured/live
/// bearing and spanning ± the uncertainty.
class _WedgePainter extends CustomPainter {
  _WedgePainter({
    required this.centerDeg,
    required this.halfWidthDeg,
    required this.color,
  });

  final double centerDeg;
  final double halfWidthDeg;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width * 0.27;
    final startAngle = _toCanvasAngle(centerDeg - halfWidthDeg);
    final sweep = (halfWidthDeg * 2) * math.pi / 180.0;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..color = color.withValues(alpha: 0.30)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(rect, startAngle, sweep, false)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WedgePainter oldDelegate) =>
      oldDelegate.centerDeg != centerDeg ||
      oldDelegate.halfWidthDeg != halfWidthDeg ||
      oldDelegate.color != color;
}

class _ReadoutDisc extends StatelessWidget {
  const _ReadoutDisc({
    this.magneticBearingDeg,
    this.trueBearingDeg,
    this.uncertaintyDeg,
  });

  final double? magneticBearingDeg;
  final double? trueBearingDeg;
  final double? uncertaintyDeg;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    final scheme = Theme.of(context).colorScheme;
    final headline = magneticBearingDeg == null
        ? '—'
        : '${magneticBearingDeg!.round()}°';
    final split = magneticBearingDeg == null
        ? ''
        : 'M ${magneticBearingDeg!.round()}°'
            '${trueBearingDeg != null ? ' · T ${trueBearingDeg!.round()}°' : ''}';
    final uncertainty =
        uncertaintyDeg == null ? '' : '±${uncertaintyDeg!.round()}° uncert.';

    return Container(
      width: 112,
      height: 112,
      decoration: BoxDecoration(
        color: scheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: scheme.outline, width: 1),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 8),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(headline,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w800, color: scheme.onSurface)),
          if (split.isNotEmpty)
            Text(split,
                style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    color: colors.compassMagneticNeedle)),
          if (uncertainty.isNotEmpty)
            Text(uncertainty,
                style: TextStyle(fontSize: 8, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// Renders like a real bubble level: the bubble drifts off-center with tilt
/// (clamped to stay within the vial) and turns green only once level.
class _LevelBadge extends StatelessWidget {
  const _LevelBadge({
    required this.isLevel,
    required this.offsetX,
    required this.offsetY,
  });

  final bool isLevel;
  final double offsetX;
  final double offsetY;

  static const _vialRadius = 21.0;
  static const _bubbleRadius = 7.0;
  static const _maxTravel = _vialRadius - _bubbleRadius - 2;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    final scheme = Theme.of(context).colorScheme;

    // offsetX/offsetY are the ~-1..1 horizontal components of the device's
    // "up" vector; clamp the resulting drift to the vial's inner radius so
    // the bubble can't visually escape the badge at steep tilts.
    var dx = offsetX * _maxTravel * 2;
    // Negate the pitch (device +y) axis: a real spirit-level bubble drifts
    // toward the raised edge, which is the opposite screen direction from the
    // raw accelerometer +y component. Roll (dx) already reads correctly.
    var dy = -offsetY * _maxTravel * 2;
    final travel = math.sqrt(dx * dx + dy * dy);
    if (travel > _maxTravel) {
      final scale = _maxTravel / travel;
      dx *= scale;
      dy *= scale;
    }

    return Column(
      children: [
        Container(
          width: _vialRadius * 2,
          height: _vialRadius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surface,
            border: Border.all(color: scheme.outline, width: 1.5),
          ),
          child: Center(
            child: Transform.translate(
              offset: Offset(dx, dy),
              child: Container(
                width: _bubbleRadius * 2,
                height: _bubbleRadius * 2,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isLevel ? colors.animalFix : colors.fairAmber,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text('LEVEL',
            style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

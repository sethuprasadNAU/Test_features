import 'package:flutter/material.dart';

/// A teardrop map pin, drawn so its tip always lands at the exact
/// bottom-center of its own layout box, by construction.
///
/// Task 11.102: the navigation-target flag used to be a bare `Icon(Icons.flag)`
/// with `alignment: Alignment.topCenter` on its `flutter_map` `Marker` — an
/// anchor that assumes the glyph's *visual* tip sits at the top-center of its
/// bounding box. `Icons.flag`'s pole runs down the glyph's left edge, not its
/// center, so the marker was drawn about 13 pixels away from the point it was
/// meant to mark. The truth-point and shared-observation-preview markers hit
/// the same class of bug (task 11.100) for a symmetric shape's *center*
/// instead of a flag's tip, fixed there with a hand-picked `Alignment`
/// fraction and a comment.
///
/// This widget takes the other option task 11.102 preferred: **make the
/// anchor true by how the shape is drawn**, not by compensating for it. A
/// font glyph's visual bounds are decided by whatever icon font ships with
/// the Flutter SDK and can silently shift between versions; a shape this
/// widget draws itself is guaranteed to tip out exactly at
/// `Offset(size.width / 2, size.height)` — i.e. always safe to place on a
/// `flutter_map` `Marker` with `alignment: Alignment.bottomCenter`, no
/// per-marker fraction needed. [tipOffsetFor] exposes that invariant so a
/// test can check the painted geometry actually agrees with it, rather than
/// trusting the doc comment — see `map_pin_marker_test.dart`.
class MapPinMarker extends StatelessWidget {
  const MapPinMarker({super.key, required this.color, this.size = 32});

  final Color color;
  final double size;

  /// The point this widget's paint geometry always tips out at, for a given
  /// box [size] — the anchor invariant this widget exists to guarantee.
  static Offset tipOffsetFor(Size size) => Offset(size.width / 2, size.height);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _PinPainter(color: color)),
    );
  }
}

class _PinPainter extends CustomPainter {
  _PinPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final tip = MapPinMarker.tipOffsetFor(size);
    final radius = size.width * 0.28;
    final circleCenter = Offset(size.width / 2, radius * 1.15);

    // Teardrop = a circle unioned with a triangle whose base spans the
    // circle's equator and whose apex is the anchor tip — a standard "map
    // pin" construction, kept purely geometric (no font metrics involved) so
    // [MapPinMarker.tipOffsetFor] stays true regardless of platform or SDK.
    final circlePath = Path()
      ..addOval(Rect.fromCircle(center: circleCenter, radius: radius));
    final trianglePath = Path()
      ..moveTo(circleCenter.dx - radius, circleCenter.dy)
      ..lineTo(circleCenter.dx + radius, circleCenter.dy)
      ..lineTo(tip.dx, tip.dy)
      ..close();
    final pinPath = Path.combine(PathOperation.union, circlePath, trianglePath);

    canvas.drawPath(pinPath, Paint()..color = color);
    canvas.drawPath(
      pinPath,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(circleCenter, radius * 0.35, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _PinPainter oldDelegate) => oldDelegate.color != color;
}

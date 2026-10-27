import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/widgets/segmented_toggle.dart';

/// Task 11.203: Michael saw the active segment's green fill covering the
/// control's own border ink, in the rounded corners only. `Container` clips
/// its child to the decoration's OUTER rounded path, but the border insets
/// the child as a plain rectangle — so in a corner, the child's square
/// corner reaches past the border's inner arc and paints over ink that is
/// still there. This test renders the real pixels and checks the corner
/// directly, rather than trusting that the clip fix was applied correctly.
void main() {
  testWidgets('the active segment does not paint over the border ink in a rounded corner', (tester) async {
    const scheme = ColorScheme.light(primary: Colors.green, onSurface: Colors.black);
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme),
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 160,
                child: SegmentedToggle<int>(
                  options: const [(0, 'One'), (1, 'Two')],
                  selected: 0,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // `toImage`/`toByteData` do real async rasterization work that never
    // resolves under the fake-async pump clock (`map_pin_marker_test.dart`
    // documents the same reasoning).
    final ui.Image image = await tester.runAsync(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      return boundary.toImage();
    }).then((v) => v!);
    final byteData = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ).then((v) => v!);

    ui.Color colorAt(double x, double y) {
      final px = x.round().clamp(0, image.width - 1);
      final py = y.round().clamp(0, image.height - 1);
      final offset = (py * image.width + px) * 4;
      return Color.fromARGB(
        byteData.getUint8(offset + 3),
        byteData.getUint8(offset),
        byteData.getUint8(offset + 1),
        byteData.getUint8(offset + 2),
      );
    }

    int channel(double c) => (c * 255.0).round().clamp(0, 255);
    bool closeTo(Color a, Color b, {int tolerance = 24}) {
      return (channel(a.r) - channel(b.r)).abs() <= tolerance &&
          (channel(a.g) - channel(b.g)).abs() <= tolerance &&
          (channel(a.b) - channel(b.b)).abs() <= tolerance;
    }

    // The outer border is a 10-radius rounded rect, 1.5 wide, so its ring
    // runs from radius 8.5 to 10 (both arcs centered at (10,10) from this
    // corner). (3,3) sits at distance ~9.9 from that center — inside the
    // border ring, and past the fixed inner clip at radius 8.5, but still
    // inside the *old*, un-arced 1.5px rectangular inset the bug painted
    // over it with. It is solid ink, not an antialiased edge pixel.
    final corner = colorAt(3, 3);
    expect(
      closeTo(corner, scheme.onSurface),
      isTrue,
      reason: 'pixel (3,3) in the top-left corner should be border ink '
          '(${scheme.onSurface}), not covered by the active segment\'s fill; got $corner',
    );
    expect(
      closeTo(corner, scheme.primary),
      isFalse,
      reason: 'pixel (3,3) should not be the active segment\'s fill colour '
          '(${scheme.primary}) — that is the corner-ink bug; got $corner',
    );
  });
}

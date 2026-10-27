import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/widgets/map_pin_marker.dart';

/// Task 11.102: [MapPinMarker] exists specifically so the navigation-flag
/// marker's anchor doesn't depend on a font glyph's visual bounds (which is
/// what put the old `Icons.flag` marker ~13px off). Its whole job is to
/// guarantee the shape it paints tips out at `tipOffsetFor(size)` — this test
/// renders the actual painted pixels and checks that promise directly,
/// rather than trusting the doc comment. If a future edit to `_PinPainter`
/// ever moves the tip away from that offset, this test — not a person
/// eyeballing the map — is what catches it.
void main() {
  testWidgets('the painted pin is opaque at its documented tip and transparent well above it', (tester) async {
    const size = 32.0;
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: const MapPinMarker(color: Colors.blue, size: size),
          ),
        ),
      ),
    );

    final tip = MapPinMarker.tipOffsetFor(const Size(size, size));

    // `toImage`/`toByteData` do real async rasterization work that never
    // resolves under the fake-async pump clock — same reasoning
    // `map_screen_test.dart` documents for its own `runAsync` use.
    final ui.Image image = await tester.runAsync(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      return boundary.toImage();
    }).then((v) => v!);
    final byteData = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ).then((v) => v!);

    int alphaAt(double x, double y) {
      final px = x.round().clamp(0, image.width - 1);
      final py = y.round().clamp(0, image.height - 1);
      final offset = (py * image.width + px) * 4;
      return byteData.getUint8(offset + 3);
    }

    // One pixel above the documented tip — inside the painted triangle,
    // proving the pin's point actually reaches down to the box's bottom
    // edge rather than stopping short the way `Icons.flag` visually did
    // relative to its own layout box.
    expect(
      alphaAt(tip.dx, tip.dy - 1),
      greaterThan(0),
      reason: 'the pin should be opaque one pixel above its documented tip offset',
    );

    // The box's top-left corner is outside the circle/triangle union
    // entirely — sanity check that this isn't trivially true everywhere.
    expect(
      alphaAt(1, 1),
      0,
      reason: 'a corner well outside the pin shape should be fully transparent',
    );
  });

  test('tipOffsetFor is always the box bottom-center, for any size', () {
    expect(MapPinMarker.tipOffsetFor(const Size(32, 32)), const Offset(16, 32));
    expect(MapPinMarker.tipOffsetFor(const Size(40, 60)), const Offset(20, 60));
  });
}

import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'app_shell_harness.dart';

/// **The regression requirement of task 11.204, and it outranked the change
/// it guards.**
///
/// `clearBandFromRects` used to charge every overlay the subject's full width
/// whatever its own width. Task 11.204 made it charge each overlay the width
/// it actually covers, and floor the resulting region in both directions
/// ([kClearRegionMinWidth]). **On every layout that existed before task
/// 11.203 — where every overlay really was full width — the new computation
/// has to reproduce the old numbers exactly.** A measurement that cannot
/// reproduce what the old one said about the old inputs is a different
/// instrument, not a better one.
///
/// So the old computation is written out below, unchanged, and the two are
/// run against the same randomly generated full-width overlay sets.
void main() {
  /// The pre-task-11.204 computation, copied verbatim from
  /// `app_shell_harness.dart` at commit 870fa74. **Do not "improve" it** —
  /// its only job is to be what the instrument used to say.
  double legacyClearBand(Rect area, List<Rect> overlays) {
    final blocked = <(double, double)>[];
    for (final r in overlays) {
      if (r.bottom <= area.top || r.top >= area.bottom) continue;
      if (r.height <= 0) continue;
      blocked.add((
        r.top.clamp(area.top, area.bottom),
        r.bottom.clamp(area.top, area.bottom),
      ));
    }
    blocked.sort((a, b) => a.$1.compareTo(b.$1));
    var best = 0.0;
    var cursor = area.top;
    for (final (top, bottom) in blocked) {
      if (top > cursor) best = best > top - cursor ? best : top - cursor;
      if (bottom > cursor) cursor = bottom;
    }
    if (area.bottom > cursor) {
      best = best > area.bottom - cursor ? best : area.bottom - cursor;
    }
    return best;
  }

  const area = Rect.fromLTWH(0, 0, 390, 500);

  test('a full-width overlay set measures exactly what it used to', () {
    // Seeded, so a failure is reproducible rather than a story about a run.
    final random = Random(11204);
    for (var trial = 0; trial < 2000; trial++) {
      final overlays = <Rect>[];
      final count = random.nextInt(6);
      for (var i = 0; i < count; i++) {
        final top = random.nextDouble() * 520 - 10;
        final height = random.nextDouble() * 120;
        // Full width, which is what every overlay on these three screens was
        // before task 11.203: a band across the map, or a control column
        // whose `Positioned` still measured the map's whole width.
        overlays.add(Rect.fromLTRB(area.left, top, area.right, top + height));
      }
      expect(
        clearBandFromRects(area, overlays),
        moreOrLessEquals(legacyClearBand(area, overlays), epsilon: 1e-9),
        reason: 'Full-width overlays: $overlays',
      );
    }
  });

  test('an overlay wider than the subject is still full width', () {
    // Clipping is the other half of "the old inputs": a `Positioned` band can
    // measure wider than the `Stack` it sits in.
    final overlays = [const Rect.fromLTRB(-40, 100, 500, 148)];
    expect(clearBandFromRects(area, overlays), legacyClearBand(area, overlays));
  });

  group('what the change is for', () {
    test('a corner square costs the band nothing', () {
      // Task 11.203's two stacked 48-pixel squares, in the corner. The old
      // computation charged them a full-width band 104 tall and cut the
      // Position map from 96 to 49.8.
      final overlays = [
        const Rect.fromLTWH(334, 200, 48, 48),
        const Rect.fromLTWH(334, 256, 48, 48),
      ];
      expect(clearBandFromRects(area, overlays), 500.0);
      expect(legacyClearBand(area, overlays), lessThan(300.0));
    });

    test('furniture accumulating along one edge still costs the band', () {
      // The old comment's reason, which the width floor is what preserves.
      // A column down the right-hand side wide enough to leave under
      // [kClearRegionMinWidth] beside it blocks its rows exactly as a
      // full-width band would.
      final overlays = [
        Rect.fromLTRB(area.right - 320, 200, area.right, 248),
      ];
      expect(clearBandFromRects(area, overlays), 252.0);
    });

    test('the region has to be wide somewhere, not wide on average', () {
      // Two overlays that leave a 100-pixel gap each, on opposite edges, but
      // never the same 100 pixels at the same height. The tallest clear
      // rectangle is bounded by them, not by their union's height.
      final overlays = [
        Rect.fromLTRB(0, 100, area.right - 40, 148),
        Rect.fromLTRB(40, 148, area.right, 196),
      ];
      expect(clearBandFromRects(area, overlays), 304.0);
    });
  });

  test('the width floor is stated once and used', () {
    // The floor is a fact about the measurement, not a number each caller
    // picks — a caller that could pass its own would be able to make its own
    // screen pass.
    expect(kClearRegionMinWidth, 96.0);
    final justTooNarrow = [
      Rect.fromLTRB(0, 0, area.right - (kClearRegionMinWidth - 1), 250),
    ];
    expect(clearBandFromRects(area, justTooNarrow), 250.0);
    final justWideEnough = [
      Rect.fromLTRB(0, 0, area.right - kClearRegionMinWidth, 250),
    ];
    expect(clearBandFromRects(area, justWideEnough), 500.0);
  });
}

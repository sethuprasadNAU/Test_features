import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/compass/bearing_capture.dart';

void main() {
  group('single point', () {
    test('captures the current heading with the default uncertainty', () {
      final c = BearingCaptureController(defaultUncertaintyDeg: 12);
      final b = c.captureSinglePoint(145.0);
      expect(b.magneticBearingDeg, closeTo(145, 1e-9));
      expect(b.uncertaintyDeg, closeTo(12, 1e-9));
      expect(b.method, CaptureMode.singlePoint);
    });

    test('normalizes an out-of-range heading', () {
      final c = BearingCaptureController();
      expect(c.captureSinglePoint(-15).magneticBearingDeg, closeTo(345, 1e-9));
    });

    test('honors an explicit uncertainty override', () {
      final c = BearingCaptureController();
      expect(c.captureSinglePoint(90, uncertaintyDeg: 5).uncertaintyDeg,
          closeTo(5, 1e-9));
    });
  });

  group('range capture', () {
    test('midpoint and half-sweep across north (350°→10° = 0° ± 10°)', () {
      final c = BearingCaptureController()..setMode(CaptureMode.rangeCapture);
      c.markRangeStart(350);
      final b = c.markRangeEnd(10)!;
      expect(b.magneticBearingDeg, closeTo(0, 1e-9));
      expect(b.uncertaintyDeg, closeTo(10, 1e-9));
      expect(b.method, CaptureMode.rangeCapture);
      expect(b.magneticStartDeg, closeTo(350, 1e-9));
      expect(b.magneticEndDeg, closeTo(10, 1e-9));
      expect(b.ambiguousSweep, isFalse);
    });

    test('ordinary sweep 140°→150° = 145° ± 5°', () {
      final c = BearingCaptureController()..setMode(CaptureMode.rangeCapture);
      c.markRangeStart(140);
      final b = c.markRangeEnd(150)!;
      expect(b.magneticBearingDeg, closeTo(145, 1e-9));
      expect(b.uncertaintyDeg, closeTo(5, 1e-9));
    });

    test('end without start returns null', () {
      final c = BearingCaptureController()..setMode(CaptureMode.rangeCapture);
      expect(c.markRangeEnd(100), isNull);
    });

    test('a ~180° sweep is flagged ambiguous', () {
      final c = BearingCaptureController()..setMode(CaptureMode.rangeCapture);
      c.markRangeStart(0);
      expect(c.markRangeEnd(180)!.ambiguousSweep, isTrue);
    });

    test('capture clears the in-progress sweep', () {
      final c = BearingCaptureController()..setMode(CaptureMode.rangeCapture);
      c.markRangeStart(100);
      expect(c.isRangeStarted, isTrue);
      c.markRangeEnd(120);
      expect(c.isRangeStarted, isFalse);
    });

    test('switching mode cancels an in-progress sweep', () {
      final c = BearingCaptureController()..setMode(CaptureMode.rangeCapture);
      c.markRangeStart(100);
      c.setMode(CaptureMode.singlePoint);
      expect(c.isRangeStarted, isFalse);
    });
  });

  test('captured magnetic bearing converts to true north with declination', () {
    final c = BearingCaptureController();
    final b = c.captureSinglePoint(100);
    // +10° E declination → 110° true.
    expect(b.trueNorthBearingDeg(10), closeTo(110, 1e-9));
    // Near the seam: 355 + 10 = 5.
    expect(c.captureSinglePoint(355).trueNorthBearingDeg(10), closeTo(5, 1e-9));
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/features/compass/widgets/compass_dial.dart';
import 'package:tritrack/localization/angles.dart';

/// Task 11.177. Michael reported that the red magnetic needle "rotates in the
/// direction of the phone's rotation and then settles out" while the phone
/// turns, when it should never move relative to the screen.
///
/// The dial draws its ring at a *smoothed* copy of the live heading (task
/// 11.106) and every marker is positioned relative to that ring. So a marker
/// that is meant to be a *display* quantity (the live heading itself) must be
/// taken from the smoothed copy too — mixing the raw sample with the smoothed
/// ring in one subtraction produces exactly the swing Michael described.
///
/// These tests drive a turn one frame at a time and read the angle each
/// painter was actually given.

/// The `bearingDeg`/`centerDeg` a keyed layer's painter was built with.
/// The painters are private to `compass_dial.dart`; their fields are not.
double _angleAt(WidgetTester tester, ValueKey<String> key, {String field = 'bearingDeg'}) {
  final paint = tester.widget<CustomPaint>(find.byKey(key));
  final painter = paint.painter as dynamic;
  return (field == 'bearingDeg' ? painter.bearingDeg : painter.centerDeg) as double;
}

bool _hasLayer(ValueKey<String> key) => find.byKey(key).evaluate().isNotEmpty;

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: Center(child: child)),
    );

/// Pumps the dial through a turn from [from] to [to] in [steps] sensor
/// samples, calling [onFrame] after each sample *and* part-way through the
/// smoothing animation, which is where a raw-vs-smoothed mismatch is largest.
Future<void> _driveTurn(
  WidgetTester tester, {
  required double from,
  required double to,
  int steps = 12,
  double? Function(double headingDeg)? trueHeadingFor,
  double? capturedMagneticBearingDeg,
  double? uncertaintyDeg,
  double? navigationBearingDeg,
  double? inProgressRangeStartDeg,
  required void Function(double headingDeg) onFrame,
}) async {
  Widget build(double headingDeg) => _host(CompassDial(
        capturedMagneticBearingDeg: capturedMagneticBearingDeg,
        liveHeadingDeg: headingDeg,
        liveTrueHeadingDeg: (trueHeadingFor ?? (h) => null)(headingDeg),
        uncertaintyDeg: uncertaintyDeg,
        navigationBearingDeg: navigationBearingDeg,
        inProgressRangeStartDeg: inProgressRangeStartDeg,
        isLevel: true,
      ));

  await tester.pumpWidget(build(from));
  await tester.pump();

  for (var i = 1; i <= steps; i++) {
    final heading = Angles.normalizeDegrees(from + (to - from) * i / steps);
    await tester.pumpWidget(build(heading));
    // Mid-animation: the smoothed ring is still catching up to this sample.
    await tester.pump(const Duration(milliseconds: 30));
    onFrame(heading);
    await tester.pump(const Duration(milliseconds: 20));
    onFrame(heading);
  }
  // Let the smoothing settle.
  await tester.pump(const Duration(milliseconds: 200));
  onFrame(to);
}

void main() {
  testWidgets('the live magnetic needle never moves off the top of the dial during a turn',
      (tester) async {
    final seen = <double>[];
    await _driveTurn(
      tester,
      from: 0,
      to: 90,
      onFrame: (_) => seen.add(_angleAt(tester, CompassDial.needleKey)),
    );

    expect(seen, isNotEmpty);
    for (final angle in seen) {
      expect(
        angle.abs(),
        lessThan(0.001),
        reason: 'the live needle must sit at 0° (screen top) at every frame of a turn; '
            'saw ${angle.toStringAsFixed(2)}° — max seen '
            '${seen.map((a) => a.abs()).reduce((a, b) => a > b ? a : b).toStringAsFixed(2)}°',
      );
    }
  });

  testWidgets('the live needle stays at top through the 360°/0° wrap', (tester) async {
    final seen = <double>[];
    await _driveTurn(
      tester,
      from: 350,
      to: 370,
      onFrame: (_) => seen.add(_angleAt(tester, CompassDial.needleKey)),
    );
    for (final angle in seen) {
      expect(angle.abs(), lessThan(0.001), reason: 'saw ${angle.toStringAsFixed(2)}°');
    }
  });

  testWidgets('the uncertainty wedge stays centred on the live needle during a turn',
      (tester) async {
    final seen = <double>[];
    await _driveTurn(
      tester,
      from: 0,
      to: 90,
      uncertaintyDeg: 5,
      onFrame: (_) =>
          seen.add(_angleAt(tester, CompassDial.uncertaintyWedgeKey, field: 'centerDeg')),
    );
    expect(seen, isNotEmpty);
    for (final angle in seen) {
      expect(angle.abs(), lessThan(0.001), reason: 'saw ${angle.toStringAsFixed(2)}°');
    }
  });

  testWidgets('a reviewed capture DOES swing as the phone turns away from it', (tester) async {
    // The needle is a frozen captured bearing here, not the live heading —
    // it is data, and it must move relative to the screen.
    final seen = <double>[];
    await _driveTurn(
      tester,
      from: 0,
      to: 90,
      capturedMagneticBearingDeg: 0,
      onFrame: (_) => seen.add(_angleAt(tester, CompassDial.needleKey)),
    );

    // Turning the phone right by 90° puts a bearing of 0° 90° to the left.
    expect(seen.last, closeTo(-90, 0.001));
    // And it tracked the turn continuously rather than jumping at the end.
    expect(seen.where((a) => a < -20 && a > -70), isNotEmpty);
  });

  testWidgets('the true-north tick and the navigation line move with the ring, not against it',
      (tester) async {
    // True north is a fixed point in the world, so it swings — but it must
    // swing by exactly the amount the ring turned, so its angle relative to
    // the ring's own N label never changes. Declination is 10°E here, so the
    // TN tick sits 10° from the ring's north at every frame.
    final offsets = <double>[];
    final navOffsets = <double>[];
    await _driveTurn(
      tester,
      from: 0,
      to: 90,
      trueHeadingFor: (h) => Angles.normalizeDegrees(h + 10),
      navigationBearingDeg: 200,
      onFrame: (_) {
        final ringDeg =
            (tester.widget<CustomPaint>(find.byKey(CompassDial.ringKey)).painter as dynamic)
                .ringRotationDeg as double;
        // True north's magnetic-frame bearing is -declination = -10°, so the
        // tick must sit exactly where the ring has drawn -10° at every frame.
        offsets.add(Angles.shortestDifferenceDegrees(
          Angles.shortestDifferenceDegrees(ringDeg, -10),
          _angleAt(tester, CompassDial.trueNorthKey),
        ));
        navOffsets.add(Angles.shortestDifferenceDegrees(
          Angles.shortestDifferenceDegrees(ringDeg, 200 - 10),
          _angleAt(tester, CompassDial.navigationLineKey),
        ));
      },
    );

    for (final o in offsets) {
      expect(o.abs(), lessThan(0.001),
          reason: 'the true-north tick drifted ${o.toStringAsFixed(2)}° against the ring');
    }
    for (final o in navOffsets) {
      expect(o.abs(), lessThan(0.001),
          reason: 'the navigation line drifted ${o.toStringAsFixed(2)}° against the ring');
    }
  });

  testWidgets('the in-progress range sweep spans from its frozen start to the top of the dial',
      (tester) async {
    await _driveTurn(
      tester,
      from: 0,
      to: 60,
      inProgressRangeStartDeg: 0,
      onFrame: (_) {
        final painter =
            tester.widget<CustomPaint>(find.byKey(CompassDial.inProgressRangeSweepKey)).painter
                as dynamic;
        final start = painter.startRelativeDeg as double;
        final sweep = painter.sweepDeg as double;
        // The sweep must end exactly at screen top (the live heading), which
        // is where the swept band's leading edge is.
        expect(Angles.shortestDifferenceDegrees(start + sweep, 0).abs(), lessThan(0.001),
            reason: 'sweep ended at ${(start + sweep).toStringAsFixed(2)}° instead of the top');
      },
    );
  });

  testWidgets('the smoothed ring actually reaches the heading it was easing toward',
      (tester) async {
    // The smoother eases over 100 ms and `didUpdateWidget` returns early once
    // the heading stops changing, so if the animation's final frame does not
    // land on the target the gap is never closed again — a permanent offset
    // between the ring and the heading the readout prints. Measured at 7.5°
    // after a 90° turn before this was fixed.
    double ringDeg() =>
        (tester.widget<CustomPaint>(find.byKey(CompassDial.ringKey)).painter as dynamic)
            .ringRotationDeg as double;

    await _driveTurn(tester, from: 0, to: 90, onFrame: (_) {});
    expect(Angles.shortestDifferenceDegrees(ringDeg(), 90).abs(), lessThan(0.001),
        reason: 'the ring settled at ${ringDeg().toStringAsFixed(2)}° after a turn to 90°');

    // And it stays there while the heading holds steady.
    await tester.pump(const Duration(milliseconds: 500));
    expect(Angles.shortestDifferenceDegrees(ringDeg(), 90).abs(), lessThan(0.001));
  });

  testWidgets('no needle is drawn before the compass has produced a reading', (tester) async {
    await tester.pumpWidget(_host(const CompassDial(isLevel: true)));
    await tester.pump();
    expect(_hasLayer(CompassDial.needleKey), isFalse);
    expect(_hasLayer(CompassDial.trueNorthKey), isFalse);
  });
}

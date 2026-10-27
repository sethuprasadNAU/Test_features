import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/features/map/widgets/map_furniture.dart';

import '../../support/text_scale_probe.dart';

/// **The north arrow is a fixed 28-pixel circle, and its "N" grew with the
/// text size** — found by task 11.315, whose *Take on map* draws this arrow
/// whenever the map is turned facing up.
///
/// At xxxLarge, the last stop on the ordinary text-size slider, the arrow and
/// the letter no longer fit in the circle by one pixel. A test build reports
/// that as an overflow; a phone's release build draws the letter squashed and
/// says nothing. The Main Map and Position screens show the same arrow
/// whenever their map is rotated, so they had it too.
///
/// The letter is part of a glyph drawn inside a fixed box, so it does not
/// scale — the same answer task 11.139 gave the Record screen's pencil.
void main() {
  for (final scale in iosTextScalesUpward) {
    testWidgets('fits its circle at ${textScaleName(scale)}', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Center(
              child: MapNorthArrow(rotationDeg: 30, onTap: () {}),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }
}

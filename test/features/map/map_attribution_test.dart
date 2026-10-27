import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/services/tile_sources.dart';
import 'package:tritrack/features/map/widgets/map_furniture.dart';

/// Task 11.95. `/w-02`'s screenshot harness photographed the map on a
/// 6.9-inch iPhone and the map-source credit ran 61 logical pixels off the
/// right-hand edge. flutter_map's `SimpleAttributionWidget` lays its credit
/// out in a single non-wrapping `Row`, so with the default Terrain basemap —
/// whose credit is the long one — a debug build painted overflow stripes over
/// it and a release build silently clipped the tail.
///
/// The clipped case is the one that matters: showing the credit is a
/// condition of the OpenStreetMap and OpenTopoMap tile licences, and a credit
/// running off the edge of the screen is arguably not shown.
///
/// These tests assert the two halves of "readable": nothing overflows, and
/// nothing is truncated. They are deliberately font-independent. Under
/// `flutter test` the text is laid out in Ahem, whose glyphs are square and
/// therefore much wider than the real typeface, so a width these tests accept
/// is comfortably wider than what a phone actually needs — the test is
/// stricter than the field, not looser.
void main() {
  /// The widest phone the app is built for is 440 logical points; 320 is a
  /// small phone; 140 is not a real device at all and is here because a
  /// wrapping layout should degrade to more lines rather than to an
  /// exception, and a fixed-width one cannot.
  const widths = <double>[440, 320, 140];

  Future<void> pumpAt(WidgetTester tester, double width, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );
  }

  group('the map-source credit is readable on a phone (task 11.95)', () {
    for (final source in TileSources.all) {
      for (final width in widths) {
        testWidgets(
            '${source.name} at ${width.toInt()}pt: no overflow, no truncation',
            (tester) async {
          await pumpAt(tester, width, MapAttribution(source: source));

          // A `RenderFlex`/`RenderParagraph` overflow surfaces as a
          // `FlutterError` during paint in a debug build, which is exactly
          // what the phone screenshots caught.
          expect(
            tester.takeException(),
            isNull,
            reason: 'the credit overflowed at ${width}pt',
          );

          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(source.onScreenAttribution),
          );

          // The half a release build hides: `didExceedMaxLines` is what is
          // true when the text has been cut short rather than wrapped.
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: 'the credit was truncated at ${width}pt',
          );

          // And it wrapped inside the width it was given rather than
          // painting past it.
          expect(
            paragraph.size.width,
            lessThanOrEqualTo(width),
            reason: 'the credit was laid out wider than the screen at ${width}pt',
          );
        });
      }
    }

    testWidgets('the whole credit string is present, not an ellipsised prefix',
        (tester) async {
      // OpenTopoMap is the default Terrain basemap and the string that
      // overflowed. Its tail — the CC-BY-SA notice — is the part a clipping
      // layout dropped, and the part the licence is about.
      final text = TileSources.openTopoMap.attribution;
      expect(text, contains('CC-BY-SA'));
      // Task 11.133 read OpenTopoMap's terms on 2026-09-02 and left this one
      // full-length: the string is two credits under two licences, its own
      // page says the text *should* be visible rather than *must*, and the
      // licence it links is CC BY-SA 3.0, which — unlike 4.0 — has no worked
      // example blessing a link in place of the text. So the whole string is
      // still what the map paints, and the assertion below is still about the
      // string a person sees rather than one behind a button.
      expect(TileSources.openTopoMap.shortAttribution, isNull);

      await pumpAt(tester, 440, MapAttribution(source: TileSources.openTopoMap));

      expect(find.text(text), findsOneWidget);
      final rendered = tester.widget<Text>(find.text(text));
      expect(rendered.overflow, isNot(TextOverflow.ellipsis));
      expect(rendered.overflow, isNot(TextOverflow.clip));
      expect(rendered.maxLines, isNull);
    });
  });

  group('nothing goes back to the clipping widget (task 11.95)', () {
    test('no screen constructs flutter_map\'s SimpleAttributionWidget', () {
      // Fixing the two call sites is not the same as fixing the defect: the
      // widget is still exported by a package both map screens import, and
      // it is the obvious thing to reach for next time a map is added. This
      // asserts the property rather than the two instances — task 10.66.
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          // Skip the doc comment on `MapAttribution`, which names the widget
          // it replaced on purpose.
          if (line.trimLeft().startsWith('///')) continue;
          if (line.contains('SimpleAttributionWidget')) {
            offenders.add('${entity.path}:${i + 1}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'use MapAttribution: SimpleAttributionWidget cannot wrap, so '
            'the map-source credit is clipped on every phone',
      );
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/widgets/tag_color_swatch.dart';

void main() {
  group('tagColorFromHex', () {
    test('parses each channel correctly and forces full opacity', () {
      expect(tagColorFromHex('#E69F00'), const Color(0xFFE69F00));
      expect(tagColorFromHex('#000000'), const Color(0xFF000000));
      expect(tagColorFromHex('#ffffff'), const Color(0xFFFFFFFF));
    });

    test('is the exact color the Main Map uses to distinguish two tags', () {
      // Two palette colors used for two different tags' rays/estimates/
      // locations must parse to genuinely distinct Colors, not just
      // distinct strings.
      final a = tagColorFromHex('#E69F00');
      final b = tagColorFromHex('#56B4E9');
      expect(a, isNot(equals(b)));
    });
  });

  testWidgets('renders a circle in the given hex color', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: TagColorSwatch(colorHex: '#00FF00')),
    );

    final container = tester.widget<Container>(find.byType(Container));
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.shape, BoxShape.circle);
    expect(decoration.color, const Color(0xFF00FF00));
  });

  testWidgets('defaults to a 14pt size', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: TagColorSwatch(colorHex: '#123456')),
    );

    final container = tester.widget<Container>(find.byType(Container));
    expect(container.constraints, const BoxConstraints.tightFor(width: 14, height: 14));
  });

  group('TagColorSwatchStack', () {
    testWidgets('renders one swatch per color when under the max', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TagColorSwatchStack(colorHexes: ['#E69F00', '#56B4E9', '#009E73']),
        ),
      );

      expect(find.byType(TagColorSwatch), findsNWidgets(3));
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('caps display at maxShown and shows a "+N" overflow label',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: TagColorSwatchStack(
            colorHexes: ['#E69F00', '#56B4E9', '#009E73', '#D55E00', '#0072B2', '#CC79A7'],
          ),
        ),
      );

      // Default maxShown is 4; the remaining 2 collapse into "+2".
      expect(find.byType(TagColorSwatch), findsNWidgets(4));
      expect(find.text('+2'), findsOneWidget);
    });

    testWidgets('renders nothing (no overflow label) with an empty list',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: TagColorSwatchStack(colorHexes: [])),
      );

      expect(find.byType(TagColorSwatch), findsNothing);
      expect(find.textContaining('+'), findsNothing);
    });
  });
}

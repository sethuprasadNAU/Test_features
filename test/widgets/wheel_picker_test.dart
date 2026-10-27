import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/widgets/wheel_picker.dart';

void main() {
  group('WheelPicker leadingBuilder', () {
    testWidgets('renders the leading widget next to the label when provided',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WheelPicker<String>(
              items: const ['a', 'b', 'c'],
              selected: 'b',
              labelBuilder: (s) => s,
              leadingBuilder: (s) => Icon(Icons.circle, key: ValueKey('leading-$s')),
              onChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('leading-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('leading-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('leading-c')), findsOneWidget);
    });

    testWidgets('omits the leading widget for items where the builder returns null',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WheelPicker<String>(
              items: const ['a', 'sentinel'],
              selected: 'a',
              labelBuilder: (s) => s,
              leadingBuilder: (s) =>
                  s == 'sentinel' ? null : Icon(Icons.circle, key: ValueKey('leading-$s')),
              onChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('leading-a')), findsOneWidget);
      expect(find.text('sentinel'), findsOneWidget);
    });

    testWidgets('renders label-only (no Row) when leadingBuilder is not given',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WheelPicker<String>(
              items: const ['a', 'b'],
              selected: 'a',
              labelBuilder: (s) => s,
              onChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('a'), findsOneWidget);
      expect(find.byType(Row), findsNothing);
    });
  });
}

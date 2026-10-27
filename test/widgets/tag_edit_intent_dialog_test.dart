import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/format/pulse_rate_format.dart';
import 'package:tritrack/data/repositories/tag_version_repository.dart';
import 'package:tritrack/widgets/tag_edit_intent_dialog.dart';

import '../data/fixtures.dart';

/// **Task 11.32's prompt.** Editing a frequency because the transmitter drifted
/// and editing it because it was typed in wrong are the same keystrokes with
/// opposite correct answers for every bearing already recorded, so the app has
/// to ask — and the shape of the asking is the requirement, not a detail.
void main() {
  Future<TagEditIntent?> show(
    WidgetTester tester, {
    required String beforeName,
    required String afterName,
    double beforeFreq = 150.325,
    double afterFreq = 150.325,
  }) async {
    TagEditIntent? answer;
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              answer = await askTagEditIntent(
                context,
                unit: PulseRateUnit.bpm,
                before: sampleTag(tagName: beforeName, frequencyMhz: beforeFreq),
                after: sampleTag(tagName: afterName, frequencyMhz: afterFreq),
              );
              returned = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(returned, isFalse, reason: 'the dialog should still be open');
    return answer;
  }

  testWidgets('there is no default — Save is dead until a choice is made',
      (tester) async {
    // Drift and typo are both common, so either default is silently wrong a
    // good share of the time, and silence is the whole harm being fixed. This
    // is that rule as a widget: there is nothing to press until the question
    // is answered.
    await show(tester, beforeName: 'Coco', afterName: 'F21');

    final save = tester.widget<FilledButton>(
      find.byKey(const ValueKey('tag_edit_intent_save')),
    );
    expect(save.onPressed, isNull);

    for (final option in TagEditIntent.values) {
      final tile = tester.widget<RadioListTile<TagEditIntent>>(
        find.byKey(ValueKey('tag_edit_intent_${option.name}')),
      );
      // ignore: deprecated_member_use
      expect(tile.groupValue, isNull, reason: '${option.name} is preselected');
    }
  });

  testWidgets('choosing one enables Save and returns it', (tester) async {
    TagEditIntent? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              answer = await askTagEditIntent(
                context,
                unit: PulseRateUnit.bpm,
                before: sampleTag(),
                after: sampleTag(frequencyMhz: 150.51),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('tag_edit_intent_change')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tag_edit_intent_save')));
    await tester.pumpAndSettle();

    expect(answer, TagEditIntent.change);
  });

  testWidgets('dismissing without choosing abandons the edit rather than '
      'picking a side', (tester) async {
    TagEditIntent? answer = TagEditIntent.correction;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              answer = await askTagEditIntent(
                context,
                unit: PulseRateUnit.bpm,
                before: sampleTag(),
                after: sampleTag(tagName: 'F21'),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(answer, isNull);
  });

  testWidgets('it shows what actually moved, was → becomes', (tester) async {
    // Naming the fields is not enough to answer the question. "148.520 →
    // 148.535" is recognisably a drift and "F12 → F21" is recognisably a typo,
    // and the person can see which they are looking at without having to
    // remember what they typed a moment ago.
    await show(
      tester,
      beforeName: 'Coco',
      afterName: 'F21',
      beforeFreq: 148.520,
      afterFreq: 148.535,
    );
    expect(find.textContaining('148.52'), findsOneWidget);
    expect(find.textContaining('148.535'), findsOneWidget);
    expect(find.textContaining('Coco'), findsOneWidget);
    expect(find.textContaining('F21'), findsOneWidget);
    // …and only what moved: the name row is absent when only the frequency
    // changed.
    expect(find.textContaining('Pulse rate'), findsNothing);
  });

  testWidgets('both options read as the same question the observation '
      'supersede decision asks', (tester) async {
    await show(tester, beforeName: 'Coco', afterName: 'F21');
    // The copy lives on the enum so the two call sites cannot drift into
    // asking the same question two different ways.
    expect(find.text(TagEditIntent.correction.prompt), findsOneWidget);
    expect(find.text(TagEditIntent.change.prompt), findsOneWidget);
    expect(find.text(TagEditIntent.correction.consequence), findsOneWidget);
    expect(find.text(TagEditIntent.change.consequence), findsOneWidget);
  });
}

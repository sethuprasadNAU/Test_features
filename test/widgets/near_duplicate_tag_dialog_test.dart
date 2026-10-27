import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/widgets/near_duplicate_tag_dialog.dart';

import '../data/fixtures.dart';

/// Task 11.324, item 3 — **a Tag ID the project already has.**
///
/// Michael, reviewing the guide (2026-10-02): the near-duplicate warning let a
/// second tag with the same Tag ID through as its affirmative button. Now
/// *Use the existing tag* is the default and *Create anyway* is the deliberate
/// choice — for a Tag ID already on **this project**. A match that is only in
/// the person's Tag Library, or only a frequency, keeps the warning as it was.
void main() {
  late ProviderContainer container;

  Future<void> seed(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await (await container.read(userRepositoryProvider.future))
          .insert(sampleUser());
      await (await container.read(projectRepositoryProvider.future))
          .insert(sampleProject());
      await (await container.read(tagRepositoryProvider.future)).insert(
        sampleTag(id: 'tag-k7', tagName: 'K7', frequencyMhz: 150.1),
        recordInLibrary: false,
      );
      await (await container.read(tagLibraryRepositoryProvider.future)).insert(
        sampleTagLibraryEntry(id: 'lib-rex', tagName: 'Rex', frequencyMhz: 150.9),
      );
    });
  }

  Future<NewTagDecision?> ask(
    WidgetTester tester, {
    required String tagName,
    required double frequencyMhz,
    required Future<void> Function() answer,
  }) async {
    NewTagDecision? decision;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  decision = await checkNewTagAgainstExisting(
                    context,
                    ref,
                    frequencyMhz: frequencyMhz,
                    tagName: tagName,
                    projectId: 'project-1',
                  );
                },
                child: const Text('check'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('check'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await answer();
    await tester.pumpAndSettle();
    // The check began inside `runAsync` (it reads the database), so the rest
    // of its chain completes on real time, not on the fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    return decision;
  }

  testWidgets('WATCHED RED: a Tag ID on this project offers the existing tag '
      'as the default, and returns it', (tester) async {
    await seed(tester);
    final decision = await ask(
      tester,
      tagName: ' k7',
      frequencyMhz: 151.5,
      answer: () async {
        expect(find.text('Tag ID K7 is already on this project'),
            findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Use the existing tag'),
            findsOneWidget, reason: 'the default is the filled button');
        expect(find.widgetWithText(TextButton, 'Create anyway'), findsOneWidget,
            reason: 'a second tag is the deliberate, quieter choice');
        await tester.tap(find.text('Use the existing tag'));
      },
    );
    expect(decision, isA<UseExistingTag>());
    expect((decision! as UseExistingTag).tag.tagId, 'tag-k7');
  });

  testWidgets('Create anyway is still there, and still creates', (tester) async {
    await seed(tester);
    final decision = await ask(
      tester,
      tagName: 'K7',
      frequencyMhz: 151.5,
      answer: () => tester.tap(find.text('Create anyway')),
    );
    expect(decision, isA<CreateNewTag>());
  });

  testWidgets('Go back creates nothing and uses nothing', (tester) async {
    await seed(tester);
    final decision = await ask(
      tester,
      tagName: 'K7',
      frequencyMhz: 151.5,
      answer: () => tester.tap(find.text('Go back')),
    );
    expect(decision, isA<GoBackFromNewTag>());
  });

  testWidgets('a name only in the Tag Library keeps the old warning, where '
      'creating is the affirmative button', (tester) async {
    await seed(tester);
    final decision = await ask(
      tester,
      tagName: 'Rex',
      frequencyMhz: 151.5,
      answer: () async {
        expect(find.text('Use the existing tag'), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Create anyway'),
            findsOneWidget);
        await tester.tap(find.text('Create anyway'));
      },
    );
    expect(decision, isA<CreateNewTag>());
  });

  testWidgets('nothing alike asks nothing', (tester) async {
    await seed(tester);
    final decision = await ask(
      tester,
      tagName: 'Zed',
      frequencyMhz: 152.5,
      answer: () async {
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
    expect(decision, isA<CreateNewTag>());
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/more/screens/tag_database_screen.dart';
import 'package:tritrack/features/observations/screens/observation_logging_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';
import '../support/app_shell_harness.dart';
import '../support/fake_path_provider.dart';
import '../support/fake_shared_preferences.dart';
import '../support/tag_library_priming.dart';

/// **Task 11.138 — what a label costs, measured on the phone it costs it on.**
///
/// Two of this task's controls said why they were unavailable in a `Tooltip`
/// while having **no visible label at all**: the padlock on a tag row nobody
/// may edit, and the "+ Quick-add tag" button on the Record screen's empty
/// state. A tooltip needs a hover or a long press, so on a phone the whole of
/// what those two told a person was a small grey icon and a greyed button.
///
/// Giving them a label and a reason costs pixels, and this file is where that
/// cost is a number rather than a hope. **Task 11.126's rule is why it is a
/// separate file:** the suites that own these two screens pump them at
/// 800x1600 — a surface picked years ago to stop an unrelated dialog
/// overflowing — and a test surface chosen to make one thing fit is an
/// assertion about width that nobody re-examines. Everything here runs at
/// 393x852 with a real status bar and home indicator, which is the smallest
/// phone this app claims to support.
///
/// **A note on the numbers.** Under `flutter test` every glyph is a square of
/// the font size, so text is about twice as wide as Roboto. Per task 11.133
/// that makes *wrapping* costs an overstatement and *padding and fixed
/// height* costs exact. Both measurements below are of a row's height with
/// and without the new label side by side in the same run, so neither depends
/// on that difference.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
    EditableText.debugDeterministicCursor = true;
  });
  tearDown(() => EditableText.debugDeterministicCursor = false);

  /// A project owned by somebody else, one tag in it, and the person holding
  /// the phone in [role] on it. A contributor may create tags but may not
  /// *edit* one belonging to a project they do not own (task 11.11), which is
  /// the state that locks a tag row.
  Future<ProviderContainer> seed(
    WidgetTester tester, {
    required ProjectRole role,
    required int tags,
  }) async {
    final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
    final me = sampleUser(id: 'user-me', email: 'me@example.com');
    final project = sampleProject(id: 'project-1', ownerUserId: owner.userId);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith((ref) async => me),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.insert(Tables.users, owner.toColumns());
      await db.insert(Tables.users, me.toColumns());
      await db.insert(Tables.projects, project.toColumns());
      // **The Tag Database screen shows this device's tag *library* since
      // task 11.219**, so the rows this measures are library entries, not a
      // project's tags. The geometry is the same — one row per collar — and
      // the padlock this file was written about has moved to Project Setup,
      // where a project's copy can genuinely be read-only.
      final library = await container.read(tagLibraryRepositoryProvider.future);
      for (var i = 0; i < tags; i++) {
        await library.insert(
          sampleTagLibraryEntry(id: 'tag-$i', tagName: 'Coco $i'),
        );
      }
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(
          projectId: project.projectId,
          userId: me.userId,
          role: role,
        ).toColumns(),
      );
      await container
          .read(activeProjectIdProvider.notifier)
          .set(project.projectId);
      await primeTagLibrary(container);
      await container.read(deviceIdProvider.future);
      container.listen(
        mayWriteProjectDataProvider(project.projectId),
        (_, _) {},
      );
      await container.read(
        mayWriteProjectDataProvider(project.projectId).future,
      );
    });
    return container;
  }

  testWidgets('no tag row costs more than any other, whatever the role', (
    tester,
  ) async {
    // **Michael, 2026-09-06**, after task 11.138 put "view only" on the row's
    // second line: "The special notes (ie view only) should move to the tag
    // details page. This will allow all the info on the tag database table be
    // on one line (frequency name) which will allow the font size to be
    // increased a bit for readability." And, in the same breath, the concern
    // this test exists to answer: "My concern with forcing it all to one line
    // and increasing the font size is that it won't all fit on a single line
    // and then wrap."
    //
    // The old measurement here was **+20 logical pixels per locked row** —
    // one extra subtitle line, out of a possible +64 for the rejected design
    // that put the words in the `trailing` slot.
    //
    // **Task 11.219 removed the locked row from this screen rather than its
    // cost.** The Tag Database screen shows this device's own tag *library*,
    // which is in no project and which no role governs, so there is nothing
    // here for a padlock to preview. What survives is the property Michael
    // asked for and the one this file can still measure: **every row is the
    // same height, and that height does not depend on who is looking.** The
    // read-only case moved to Project Setup, where a project's copy is
    // genuinely owner-only and the reason is stated once under the section
    // (task 11.138's rule) — `project_setup_screen_test.dart` holds it.
    final asContributor = await seed(
      tester,
      role: ProjectRole.contributor,
      tags: 2,
    );
    usePhoneGeometry(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: asContributor,
        child: const MaterialApp(home: TagDatabaseScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byIcon(Icons.lock_outline),
      findsNothing,
      reason: 'a library entry is this device\'s own record of its own '
          'equipment — there is no role to lock it behind',
    );
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
    expect(
      find.textContaining('view only'),
      findsNothing,
      reason: 'the words moved to Tag details in 11.138 and the whole '
          'read-only case moved to Project Setup in 11.219',
    );
    final contributorHeight =
        tester.getRect(find.byType(ListTile).first).height;

    final asOwner = await seed(tester, role: ProjectRole.owner, tags: 2);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: asOwner,
        child: const MaterialApp(home: TagDatabaseScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
    final ownerHeight = tester.getRect(find.byType(ListTile).first).height;

    expect(
      contributorHeight,
      ownerHeight,
      reason:
          'a row must cost exactly the same to everybody. If this has grown, '
          'something went back onto the row for one role, and a person with '
          'forty tags pays for all forty.',
    );
  });

  testWidgets('the tag row holds one line at any name length and any text scale', (
    tester,
  ) async {
    // **The direct answer to Michael's concern**, and it is structural rather
    // than lucky: the tag name is the only `Flexible` piece of the line and it
    // is capped at one line, so it ellipsises and the row's height cannot
    // depend on it. The frequency — the fixed-width field somebody scans a
    // column of — is never the part that gets cut.
    //
    // This is the project's "a budget must be able to refuse" rule (tasks
    // 11.149, 11.162, 11.166) on the width axis. `maxLines: 1` is something
    // that says no; "the names are usually short" is a comment.
    //
    // **Per task 11.133 these numbers are pessimistic**: this harness draws
    // every glyph as a square of the font size, roughly twice Roboto's width,
    // so a name that ellipsises here fits on a real phone at about twice the
    // length. The *height* assertions are exact in either font, which is what
    // this test turns on.
    final container = await seed(tester, role: ProjectRole.owner, tags: 1);
    await tester.runAsync(() async {
      final repo = await container.read(tagLibraryRepositoryProvider.future);
      await repo.insert(sampleTagLibraryEntry(
        id: 'long',
        tagName: 'Kestrel Nest Site Seven — north ridge, second bird of the pair',
        frequencyMhz: 149.876,
      ));
      // `seed` already resolved this provider, so the new row is invisible
      // until it is asked again.
      container.invalidate(tagLibraryProvider);
      await primeTagLibrary(container);
    });

    for (final scale in [1.0, 1.3, 2.0]) {
      usePhoneGeometry(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            // **`copyWith`, not a fresh `MediaQueryData`.** A bare one carries
            // `Size.zero`, so the screen lays out in no space at all, nothing
            // can wrap and nothing can overflow — this test passed with
            // wrapping deliberately switched back on until that was fixed.
            // Same class as the project's own rule about a check that cannot
            // tell success from its own failure.
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: const TagDatabaseScreen(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'no overflow at text scale $scale');
      expect(tester.widgetList<ListTile>(find.byType(ListTile)).length, 2,
          reason: 'both rows render at text scale $scale');

      // **Measured on the text, not on the tile.** A `ListTile` has a minimum
      // height that quietly absorbs a second line at ordinary text sizes, so a
      // tile-height comparison passes with wrapping switched back on — checked
      // by doing exactly that. The line itself cannot hide it.
      // **Ask the paragraph how many lines it drew.** Two weaker instruments
      // were tried first and both passed with wrapping deliberately switched
      // back on, which is how they were found:
      //
      //  * `getRect` on the `Text` — a `StatelessWidget`, so the finder walks
      //    *up* to the tile's title slot, whose height is the same either way.
      //  * comparing the long row's height against the short row's — in this
      //    harness every glyph is a square of the font size, so at 393 wide
      //    **both** rows wrap and they move together. A comparison between two
      //    things that fail identically is not a comparison.
      //
      // `computeLineMetrics()` is exact, and it does not care about the font,
      // the width or the text scale.
      // The trick is the reference: laid out in effectively unlimited width,
      // *any* of these lines is exactly one line tall, whatever the font, the
      // scale or the length. Comparing a row against its own one-line height
      // needs no number anybody chose.
      void expectOneLine(String label, String fragment) {
        final paragraph = tester.renderObject<RenderBox>(find.descendant(
          of: find.textContaining(fragment),
          matching: find.byType(RichText),
        ));
        final oneLine = paragraph.getMinIntrinsicHeight(10000);
        expect(
          paragraph.size.height,
          oneLine,
          reason:
              'at text scale $scale the row with $label is '
              '${paragraph.size.height} tall against a one-line height of '
              '$oneLine — it wrapped instead of ellipsising',
        );
      }

      expectOneLine('the 60-character name', '149.876 MHz');
      expectOneLine('an ordinary name', '150.325 MHz');

      // And the tile follows, which is the thing a person actually sees.
      expect(
        tester.getRect(find.byType(ListTile).last).height,
        tester.getRect(find.byType(ListTile).first).height,
      );
      // The frequency survives intact at every scale; only the name gives way.
      expect(find.textContaining('149.876 MHz'), findsOneWidget);
    }
  });

  testWidgets('a viewer with no tags reads why "+ Quick-add tag" is greyed', (
    tester,
  ) async {
    final container = await seed(tester, role: ProjectRole.viewer, tags: 0);
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ObservationLoggingScreen(),
      tabIndex: 1, // Map / **Record** / Compass / Position / More
    );

    expect(tester.takeException(), isNull);
    expect(find.text('No tags in this project yet'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, '+ Quick-add tag'),
          )
          .onPressed,
      isNull,
    );
    // On the control, where a phone can read it — not in a tooltip.
    expect(
      find.text(
        'Viewers cannot create tags — ask an owner to change your role.',
      ),
      findsOneWidget,
    );
  });
}

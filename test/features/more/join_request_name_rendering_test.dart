import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/features/more/screens/project_members_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.85 — what a claimed name *renders* as, not what it stores as.**
///
/// The owner's pending list is the one screen in this app where a person
/// decides whether to trust somebody by reading a string, and
/// `RowValidator.isWellFormedPersonName` exists to stop a requester making
/// their name render as somebody else's. Round 9's live attack
/// (`scripts/verify_11_9_team_surface.py`, probe 9) established which strings
/// the server admits. **This file establishes what the admitted ones do on
/// screen**, because a test that only checks the string is stored intact has
/// not asked the question the control exists to answer.
///
/// **Finding R-1 lives here.** `U+2028 LINE SEPARATOR` and `U+2029 PARAGRAPH
/// SEPARATOR` are line terminators rather than bidirectional controls, so the
/// validator's two character classes — C0/C1 controls, and the bidi
/// overrides — miss both, and a requester can put a line break in a name.
/// These cases are written to **assert the behaviour that is live today** and
/// to say so, rather than to fail: a red test nobody can make green is a test
/// that gets deleted. When the validator is fixed they will fail, loudly, on
/// the line that names R-1 — which is the point.
void main() {
  const projectId = 'project-1';
  const owner = 'user-owner';

  setUp(installFakeSharedPreferences);

  /// The character offsets at which each rendered line after the first
  /// begins, measured from the render object one character at a time.
  ///
  /// **The measurement has to come from the layout**, because whether a
  /// character breaks a line is a property of the text engine and not of the
  /// code-point table somebody wrote down.
  ///
  /// **It has to be the offsets and not the count**, and finding that out is
  /// what this file's own self-test was for. The first version of these cases
  /// asserted "two lines", ran green, and *stayed* green against a build with
  /// U+2028 stripped out of the tile — because the attack string was long
  /// enough to wrap onto two lines on its own. A check that reports the same
  /// answer with the control removed is not a check, which is this project's
  /// standing rule (task 10.66) and was very nearly broken here.
  List<int> lineBreakOffsets(WidgetTester tester, Finder finder) {
    final paragraph = tester.renderObject<RenderParagraph>(finder);
    final text = paragraph.text.toPlainText();
    final breaks = <int>[];
    double? previousTop;
    for (var i = 0; i < text.length; i++) {
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: i, extentOffset: i + 1),
      );
      if (boxes.isEmpty) continue;
      final top = boxes.map((ui.TextBox b) => b.top).reduce(math.min);
      if (previousTop != null && (top - previousTop).abs() > 0.5) {
        breaks.add(i);
      }
      previousTop = top;
    }
    return breaks;
  }

  int renderedLineCount(WidgetTester tester, Finder finder) =>
      lineBreakOffsets(tester, finder).length + 1;

  Future<ProviderContainer> seed({
    required List<JoinRequestSummary> joinRequests,
  }) async {
    final project = sampleProject(id: projectId, ownerUserId: owner);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith(
          (ref) async => sampleUser(id: owner, email: '$owner@x.com'),
        ),
        projectJoinSettingsProvider(projectId).overrideWith(
          (ref) async => const JoinSettings(
            projectId: projectId,
            joiningEnabled: true,
            teamSizeLimit: 50,
            memberCount: 1,
            pendingCount: 1,
          ),
        ),
        projectJoinRequestsProvider(
          projectId,
        ).overrideWith((ref) async => joinRequests),
      ],
    );
    final db = (await container.read(appDatabaseProvider.future)).raw;
    await db.insert(
      Tables.users,
      sampleUser(id: owner, email: '$owner@x.com').toColumns(),
    );
    await db.insert(Tables.projects, project.toColumns());
    await db.insert(
      Tables.projectMemberships,
      ProjectMembership(
        membershipId: 'm-owner',
        projectId: projectId,
        userId: owner,
        joinDate: DateTime.utc(2026, 8, 1),
        role: ProjectRole.owner,
        sync: SyncMeta.initial(now: DateTime.utc(2026, 8, 1), modifiedBy: owner),
      ).toColumns(),
    );
    container.listen(isProjectOwnerProvider(projectId), (_, _) {});
    container.listen(projectMembershipsProvider(projectId), (_, _) {});
    await container.read(isProjectOwnerProvider(projectId).future);
    await container.read(projectMembershipsProvider(projectId).future);
    return container;
  }

  JoinRequestSummary request({
    String email = 'stranger@example.invalid',
    String? claimedName,
  }) => JoinRequestSummary(
    requestId: 'req-1',
    projectId: projectId,
    email: email,
    claimedName: claimedName,
    requestedAt: DateTime.utc(2026, 8, 20).toIso8601String(),
  );

  Future<ProviderContainer> pumpWith(
    WidgetTester tester,
    JoinRequestSummary summary,
  ) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await seed(joinRequests: [summary]);
    });
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ProjectMembersScreen(projectId: projectId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('the properties that hold', () {
    testWidgets('the authenticated address is its own widget, not part of the '
        'claim', (tester) async {
      // The name cannot *replace* the address however it renders: they are two
      // widgets, and the email is the tile's title. A claim that reads like an
      // address is still under a heading that is the real one.
      //
      // **Task 11.89 note.** The claimed name below is one the server now
      // refuses outright — an address is not a name — so this is defence in
      // depth rather than the property that keeps the screen honest. It is
      // kept because the two guarantees are independent: the validator says
      // what may be stored, and this says the tile does not let a stored
      // string stand in for the identifier the owner is deciding on.
      await pumpWith(
        tester,
        request(
          email: 'stranger@example.invalid',
          claimedName: 'michael.w.shafer@nau.edu',
        ),
      );
      expect(find.text('stranger@example.invalid'), findsOneWidget);
      expect(find.text('michael.w.shafer@nau.edu'), findsNothing);
      expect(
        find.text('Says they are michael.w.shafer@nau.edu'),
        findsOneWidget,
      );
    });

    testWidgets('an ordinary name lays out as exactly one line', (
      tester,
    ) async {
      // The positive control for every measurement below. Without it, "two
      // lines" would prove nothing: a tile narrow enough to wrap every name
      // would report two lines for a name with no separator in it at all.
      await pumpWith(tester, request(claimedName: 'Dana Reyes'));
      expect(
        renderedLineCount(tester, find.text('Says they are Dana Reyes')),
        1,
      );
    });

    testWidgets('a right-to-left name lays out as one line too', (
      tester,
    ) async {
      // The validator refuses the bidi *controls* and must not refuse
      // right-to-left letters — a real name in Hebrew or Arabic lays out
      // correctly from the letters themselves.
      await pumpWith(tester, request(claimedName: 'אליס'));
      expect(
        renderedLineCount(
          tester,
          find.text('Says they are אליס'),
        ),
        1,
      );
    });
  });

  /// **Task 11.89 closed R-1, and this group is what replaced its two cases.**
  ///
  /// The old cases asserted the defect — that `U+2028` and `U+2029` broke the
  /// claim exactly where the requester put them — and said in so many words
  /// that when the validator was fixed they should fail loudly and be deleted.
  /// They have been.
  ///
  /// **What stands here instead is the acceptance criterion as a property**,
  /// not as two more code points: *no name the validator accepts can put a
  /// line break on this tile.* That distinction is the whole of the finding.
  /// R-1 was not "two characters were missing from a list"; it was that a list
  /// of forbidden characters, written deliberately three days earlier by
  /// somebody thinking about exactly this attack, was already incomplete and
  /// had no way to say so. A test naming U+2028 and U+2029 would have the same
  /// defect as the rule it was checking.
  ///
  /// **The measurement is the layout, deliberately.** Whether a character
  /// breaks a line is a property of the text engine, not of a table somebody
  /// wrote down — so this asks the render object, exactly as the R-1 cases
  /// did. And the fix is in the validator rather than in this screen: the plan
  /// entry is explicit that changing the tile's layout would be the wrong
  /// repair, because the layout is *why* R-1 stayed below the bar, and making
  /// it the fix means the next layout change silently reopens the finding.
  group('no name the validator accepts can break this tile', () {
    /// The characters Unicode gives mandatory-break behaviour (UAX #14 class
    /// BK, plus CR and LF), which is the complete set of ways a string can
    /// force a new line without wrapping.
    ///
    /// Every one must be **refused by the validator** — asserted below through
    /// the real shared predicate, so this is the same rule the server applies
    /// to a join request and not a second copy of it.
    const mandatoryBreaks = <int, String>{
      0x000a: 'LINE FEED',
      0x000b: 'LINE TABULATION',
      0x000c: 'FORM FEED',
      0x000d: 'CARRIAGE RETURN',
      0x0085: 'NEXT LINE',
      0x2028: 'LINE SEPARATOR',
      0x2029: 'PARAGRAPH SEPARATOR',
    };

    test('every character that can force a line is refused before it is '
        'stored', () {
      for (final entry in mandatoryBreaks.entries) {
        final name = 'Ann${String.fromCharCode(entry.key)}michael@example.org';
        expect(
          RowValidator.isWellFormedPersonName(name),
          isFalse,
          reason:
              'U+${entry.key.toRadixString(16).toUpperCase().padLeft(4, '0')} '
              '${entry.value} can put a second line on the approval tile, and '
              'the requester chooses what it says',
        );
      }
    });

    // **The other half, and the half an allowlist actually risks.** Refusing
    // everything would pass the test above and be useless, so each entry here
    // is a name shape the allowlist was widened to keep, pumped through the
    // real tile and measured.
    //
    // U+3000 and U+00A0 are the two that matter: both are spaces, both were
    // close calls while the rule was being written, and a rule permitting only
    // U+0020 would have refused a great many Japanese names. Unicode separates
    // spaces (Zs) from line and paragraph separators (Zl, Zp), and that
    // distinction is what the rule is built on — so this measures that the
    // distinction is real on screen and not only in the standard.
    //
    // One `testWidgets` each rather than a loop inside one: pumping this
    // screen several times in a single test leaves the previous screen's
    // timers pending, which fails the test for a reason that has nothing to do
    // with what it is measuring.
    const accepted = <String, String>{
      'an ideographic space (U+3000), the Japanese word space': '田中　花子',
      'a no-break space (U+00A0), what a paste leaves behind': 'Dana Reyes',
      'a zero-width non-joiner (U+200C), needed by Persian names': 'Ali‌Reza',
      'a katakana middle dot (U+30FB)': 'ジョン・スミス',
      'an em dash': 'Jean—Luc',
    };
    for (final entry in accepted.entries) {
      testWidgets('${entry.key} is accepted and lays out as one line', (
        tester,
      ) async {
        expect(
          RowValidator.isWellFormedPersonName(entry.value),
          isTrue,
          reason:
              '${entry.key} is part of somebody\'s real name; an allowlist '
              'that refuses it has failed in the direction that costs a person',
        );
        await pumpWith(tester, request(claimedName: entry.value));
        expect(
          lineBreakOffsets(tester, find.textContaining('Says they are')),
          isEmpty,
          reason: '${entry.key} must not break the claim onto a second line',
        );
      });
    }

    testWidgets('the measurement can still see a break — the in-test control', (
      tester,
    ) async {
      // **Without this the group above is worthless.** "It rendered as one
      // line" is also what a broken measurement says, and this file has been
      // caught by exactly that once already: its first draft asserted a line
      // *count*, ran green, and stayed green against a build with U+2028
      // stripped out, because the attack string wrapped on its own.
      //
      // So: feed the tile a string the validator would refuse, and require the
      // measurement to report the break. If this ever comes back empty, every
      // `isEmpty` above is reporting the instrument's silence rather than the
      // rule's success.
      const prefix = 'Says they are ';
      await pumpWith(tester, request(claimedName: 'Ann Bob'));
      expect(
        lineBreakOffsets(tester, find.textContaining('Says they are Ann')),
        [prefix.length + 'Ann'.length + 1],
        reason:
            'the render object no longer reports a break for U+2028, so this '
            'file can no longer tell a name that breaks the tile from one that '
            'does not — fix the measurement before believing anything above',
      );
      expect(
        RowValidator.isWellFormedPersonName('Ann Bob'),
        isFalse,
        reason:
            'and the string used for that control is exactly what the rule now '
            'refuses, which is the closure of R-1',
      );
    });

    testWidgets('the tile title is the authenticated address, whatever the '
        'claim is', (tester) async {
      // **Kept from the R-1 cases, because it is why R-1 was below the bar and
      // it is still true.** The claim sits under a title the requester does
      // not control. This is now defence in depth rather than the reason
      // nothing had to be done: the string below is one the server refuses
      // outright since this task, and the tile would still be honest if it
      // somehow arrived.
      await pumpWith(tester, request(claimedName: 'Ann Bob'));
      expect(find.text('stranger@example.invalid'), findsOneWidget);
      expect(find.textContaining('Asked '), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Approve'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

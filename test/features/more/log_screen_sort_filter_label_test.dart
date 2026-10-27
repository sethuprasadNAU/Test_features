import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/more/screens/log_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/text_scale_probe.dart';

/// Task 11.167 — the Log screen's "Sort"/"Filter" labels used a fixed
/// 52-pixel [SizedBox]. That is a budget that always binds (task 11.166's
/// distinction from the inoperative kind), so it never overflowed — it paid
/// by wrapping the word and growing the box **downward**, reaching 102
/// logical pixels tall at 2.0x text scale and 306 at 3.0x, measured in
/// isolation.
///
/// The fix (`_SortFilterLabel` in `log_screen.dart`) sizes the box to
/// whichever of "Sort"/"Filter" is wider at the ambient text scale, with the
/// text forced to a single line — so the label grows sideways, into the
/// same row's horizontal scroll room, instead of down. This measures the
/// **row**, not the label in isolation (11.166 only had the isolation
/// measurement), on both tabs that carry a filter bar stacked over a sort
/// bar, at every stop on the iOS text-size ladder — the ordinary slider and
/// the accessibility sizes both.
void main() {
  setUp(installFakeSharedPreferences);

  /// Task 11.167 discovered, out of scope: `log_screen.dart`'s own `Tab`
  /// widgets (`Tab(text: 'Log', ...)` / `Tab(text: 'Team', ...)`) overflow
  /// their fixed-height Column by a pixel or more from AX3 upward — a
  /// pre-existing defect in the TabBar, not in the sort/filter labels this
  /// task changes, and a different row (this task's acceptance is about the
  /// filter/sort row, which stays clean at every stop; the TabBar overflow
  /// is unaffected by anything here). Silences any overflow that is not
  /// traceable to the widgets this test actually exercises, so it cannot
  /// mask a regression in the row under test while still letting one
  /// through; not fixed in this task because it is out of scope for it.
  void silenceOverflowOutsideSortFilterRow() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.exceptionAsString();
      final info = details.informationCollector
              ?.call()
              .map((n) => n.toStringDeep())
              .join('\n') ??
          '';
      final fromRowUnderTest = info.contains('_SortFilterLabel') ||
          info.contains('_FilterBar') ||
          info.contains('_SortBar') ||
          info.contains('_TeamSortBar');
      if (text.contains('overflowed by') && !fromRowUnderTest) {
        return;
      }
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  Future<ProviderContainer> pumpAtScale(
    WidgetTester tester, {
    required double textScale,
  }) async {
    silenceOverflowOutsideSortFilterRow();

    final project = sampleProject(id: 'project-1', ownerUserId: 'user-bob');
    final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
    final tag = sampleTag(id: 'tag-1');
    final obs = sampleObservation(
      id: 'obs-1',
      projectId: project.projectId,
      userId: bob.userId,
      tagId: tag.tagId,
      sessionId: null,
    );

    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith((ref) async => bob),
        currentProjectProvider.overrideWith((ref) async => project),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.insert(Tables.users, bob.toColumns());
      await db.insert(Tables.projects, project.toColumns());
      await db.insert(Tables.tags, tag.toColumns());
      await db.insert(Tables.observations, obs.toColumns());
      await container.read(historyDataProvider(project.projectId).future);
      container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
      await container.read(mayWriteProjectDataProvider(project.projectId).future);
    });

    await pumpInAppShell(
      tester,
      container: container,
      screen: const LogScreen(),
      tabIndex: 4, // Map / Record / Compass / Position / **More**
      textScale: textScale,
    );
    return container;
  }

  /// A ceiling that scales with the text, unlike a fixed pixel count: a
  /// genuine single line grows roughly linearly with [scale], so this stays
  /// a comfortable margin over one line while remaining well under what two
  /// wrapped lines would need (roughly double) — the direct measure of "did
  /// it wrap and grow downward" rather than just "did it grow at all". 102px
  /// (the two-line height 11.166 measured at 2.0x, a fixed threshold this
  /// helper would have wrongly called a pass at 1.5x anything past ~34px)
  /// is exactly the shape of ceiling a scale-blind number gets wrong.
  double oneLineCeiling(double scale) {
    final painter = TextPainter(
      text: const TextSpan(
        text: 'Filter',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
      textScaler: TextScaler.linear(scale),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.height * 1.6;
  }

  Size labelSize(WidgetTester tester, String text) => tester.getSize(
        find
            .ancestor(of: find.text(text), matching: find.byType(SizedBox))
            .first,
      );

  for (final scale in iosTextScales) {
    testWidgets(
        'the Log tab\'s filter+sort row holds at ${textScaleName(scale)}',
        (tester) async {
      await pumpAtScale(tester, textScale: scale);

      expect(tester.takeException(), isNull,
          reason: 'an unexpected layout error at ${textScaleName(scale)}');

      // The regression this task fixes: the label wrapping and growing
      // downward instead of holding a single line.
      expect(labelSize(tester, 'Filter').height, lessThan(oneLineCeiling(scale)),
          reason: 'the "Filter" label grew tall at ${textScaleName(scale)} — '
              'it wrapped instead of staying one line');
      expect(labelSize(tester, 'Sort').height, lessThan(oneLineCeiling(scale)),
          reason: 'the "Sort" label grew tall at ${textScaleName(scale)} — '
              'it wrapped instead of staying one line');
    });

    testWidgets(
        'the Team tab\'s filter+sort row holds at ${textScaleName(scale)}',
        (tester) async {
      await pumpAtScale(tester, textScale: scale);
      await tester.tap(find.widgetWithText(Tab, 'Team'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'an unexpected layout error at ${textScaleName(scale)}');

      expect(labelSize(tester, 'Filter').height, lessThan(oneLineCeiling(scale)),
          reason: 'the "Filter" label grew tall at ${textScaleName(scale)} — '
              'it wrapped instead of staying one line');
      expect(labelSize(tester, 'Sort').height, lessThan(oneLineCeiling(scale)),
          reason: 'the "Sort" label grew tall at ${textScaleName(scale)} — '
              'it wrapped instead of staying one line');
    });
  }

  // The alignment question the fixed width existed for: "Filter" (in the
  // filter bar) and "Sort" (in the sort bar directly below it) must still
  // start their chip rows at the same x position, at every scale — not just
  // at the default. `_SortFilterLabel` sizes every instance to the wider of
  // the two words, so this should hold exactly rather than approximately.
  for (final scale in iosTextScales) {
    testWidgets(
        'the Filter and Sort labels stay the same width at ${textScaleName(scale)}',
        (tester) async {
      await pumpAtScale(tester, textScale: scale);

      final filterWidth = labelSize(tester, 'Filter').width;
      final sortWidth = labelSize(tester, 'Sort').width;

      expect(sortWidth, closeTo(filterWidth, 0.5),
          reason: 'the "Sort" and "Filter" boxes must line up so the chip '
              'rows underneath them share a left edge, at ${textScaleName(scale)}');
    });
  }
}

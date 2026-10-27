import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/merge_report.dart';
import 'package:tritrack/features/more/screens/data_export_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';

/// Same reasoning as `log_screen_test.dart`: with no active
/// project id persisted, `currentProjectProvider` resolves to `null` without
/// touching the real database, so the no-project state is safe to test
/// plainly.
void main() {
  setUp(installFakeSharedPreferences);

  testWidgets('renders with backup export disabled and no CSV section when there is no project',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: DataExportScreen())),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Set up a project first.'), findsOneWidget);
    final exportButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Export project backup (.zip)'),
    );
    expect(exportButton.onPressed, isNull);
  });

  /// Finding **L-2**'s visibility half (§14.3). The receipt rendered
  /// `Refused …: 1` and never rendered `report.issues`, so a record dropped
  /// from a disaster recovery got a number and no name.
  group('the import receipt names what it refused', () {
    MergeReport reportWith(List<RowIssue> issues) => MergeReport(
          byTable: {
            Tables.observations: TableMergeStats()..refused = issues.length,
          },
          usersDeduped: 0,
          schemaMigratedFrom: latestSchemaVersion,
          currentSchemaVersion: latestSchemaVersion,
          issues: issues,
        );

    Future<void> pump(WidgetTester tester, MergeReport report) => tester
        .pumpWidget(MaterialApp(home: Scaffold(
          body: ImportReportContent(report: report),
        )));

    testWidgets('every refusal is listed with its table, row and reason',
        (tester) async {
      await pump(
        tester,
        reportWith([
          const RowIssue(
            table: Tables.observations,
            primaryKeyValue: 'obs-1/project-local',
            field: 'revision',
            message: 'sync clock leaves no room for this device\'s own edits',
          ),
        ]),
      );

      expect(find.textContaining('Refused'), findsOneWidget);
      expect(find.textContaining('obs-1/project-local'), findsOneWidget);
      expect(find.textContaining('revision'), findsOneWidget);
      expect(find.textContaining('leaves no room'), findsOneWidget);
    });

    testWidgets('a clean import says nothing about refusals', (tester) async {
      await pump(tester, reportWith(const []));

      expect(find.textContaining('Refused'), findsNothing);
      expect(find.text('Records this import did not apply:'), findsNothing);
    });

    testWidgets('past the display cap the remainder is stated, not truncated '
        'silently', (tester) async {
      // Tall enough that the whole list is laid out — the assertion is about
      // the copy the dialog contains, not about how far the user has scrolled.
      tester.view.physicalSize = const Size(1200, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pump(
        tester,
        reportWith([
          for (var i = 0; i < ImportReportContent.shownIssues + 3; i++)
            RowIssue(
              table: Tables.observations,
              primaryKeyValue: 'obs-$i/project-local',
              field: 'revision',
              message: 'sync clock is out of range',
            ),
        ]),
      );

      expect(find.textContaining('and 3 more not listed'), findsOneWidget);
    });
  });

  group('the consent dialog at 1,000 rows (task 10.87)', () {
    MergeFieldChange change(String table, String rowKey, String column,
            {Object? was = 'old', Object? becomes = 'new'}) =>
        MergeFieldChange(
          table: table,
          rowKey: rowKey,
          column: column,
          was: was,
          becomes: becomes,
        );

    MergeReport offer(List<MergeFieldChange> changes, {ImportCase? importCase}) =>
        MergeReport(
          byTable: {},
          usersDeduped: 0,
          schemaMigratedFrom: latestSchemaVersion,
          currentSchemaVersion: latestSchemaVersion,
          issues: const [],
          outcome: MergeOutcome.needsConfirmation,
          changes: changes,
          importCase: importCase ?? ImportCase.merge,
        );

    Future<void> pump(WidgetTester tester, MergeReport report) async {
      // Phone-sized on purpose: the claim is that the whole summary fits a
      // dialog a person can read, so a tall surface would hide the finding.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AlertDialog(content: ConsentSummaryContent(report: report)),
        ),
      ));
    }

    testWidgets('a thousand rewritten bearings and a dozen removed are one '
        'group of three lines, with the numbers on them', (tester) async {
      await pump(
        tester,
        offer([
          for (var i = 0; i < 1000; i++)
            change(Tables.observations, 'obs-$i/p', 'latitude',
                was: 35.0, becomes: 0.0),
          for (var i = 0; i < 12; i++)
            change(Tables.observations, 'obs-$i/p', 'deleted_at',
                was: null, becomes: '2026-09-13T00:00:00.000Z'),
        ]),
      );
      expect(find.textContaining('1012 values in 1000 records'), findsOneWidget);
      expect(find.text('Bearings · 1000 records'), findsOneWidget);
      expect(find.text('1012 values replaced · 12 records removed'),
          findsOneWidget);
      expect(find.text('deleted at, latitude'), findsOneWidget);
      expect(find.textContaining('12 records would be removed from every '
          'screen'), findsOneWidget);
      // The whole point: not a wall. Every Text in the dialog, counted.
      expect(find.byType(Text).evaluate().length, lessThan(8));
      expect(find.textContaining('more not listed'), findsNothing);
    });

    testWidgets('finding L-5: forty renames cannot push the coordinate '
        'rewrite out of sight', (tester) async {
      await pump(
        tester,
        offer([
          for (var i = 0; i < 40; i++)
            change(Tables.users, 'user-$i', 'last_name'),
          change(Tables.observations, 'obs-1/p', 'latitude',
              was: 35.19, becomes: 0.0),
        ]),
      );
      final bearings = tester.getTopLeft(find.text('Bearings · 1 record'));
      final people = tester.getTopLeft(find.text('People · 40 records'));
      expect(bearings.dy, lessThan(people.dy),
          reason: 'the bearing line is above the padding, whatever order the '
              'file emitted them in');
    });

    testWidgets('a project not on this device yet says so, and that only '
        'people are affected', (tester) async {
      await pump(
        tester,
        offer(
          [change(Tables.users, 'user-me', 'last_name')],
          importCase: ImportCase.adopt,
        ),
      );
      expect(find.textContaining('not on this device yet, so none of its '
          'records can be overwritten'), findsOneWidget);
      expect(find.textContaining('1 detail this device already holds about '
          '1 person'), findsOneWidget);
      expect(find.text('People · 1 record'), findsOneWidget);
    });
  });
}

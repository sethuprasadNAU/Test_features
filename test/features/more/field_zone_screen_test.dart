import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/time/device_time_zone.dart';
import 'package:tritrack/core/time/field_time_zone_text.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/deployment_linking.dart'
    show formatLinkDate, formatLinkInstant;
import 'package:tritrack/features/more/screens/project_setup_screen.dart';
import 'package:tritrack/widgets/went_on_date_card.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 11.331 on the screen — **a deployment day is the field's day,
/// whatever zone the phone showing it is in**, and the project's zone is
/// shown in words and can be changed with its consequence said first.
///
/// The fixtures pick instants that fall on a different date in Arizona than
/// in UTC, London and New Zealand, so a screen reading the phone's zone gets
/// a different answer in every zone the nightly check runs the suite in.
void main() {
  setUp(installFakeSharedPreferences);
  const phoenix = 'America/Phoenix';

  group('a field day reads the same on any phone', () {
    // 10 July in Arizona starts at 07:00 UTC on the 10th; a swap at 20:30
    // Arizona time is 03:30 UTC on the 11th — the 11th in London and the
    // 11th (afternoon) in New Zealand.
    final arizonaDay = fieldDayStart(DateTime(2026, 7, 10), phoenix);
    final lateSwap = fieldInstant(DateTime(2026, 7, 10, 20, 30), phoenix);

    test('a bare Arizona day prints as the 10th', () {
      expect(formatLinkDate(arizonaDay, phoenix), '2026-07-10');
      expect(formatLinkInstant(arizonaDay, phoenix), '2026-07-10');
    });

    test('a swap at 20:30 in Arizona prints as 20:30 on the 10th', () {
      expect(formatLinkInstant(lateSwap, phoenix), '2026-07-10 20:30');
      expect(formatLinkDate(lateSwap, phoenix), '2026-07-10');
    });

    testWidgets('the "went on" card prints the field date', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WentOnDateCard(
              label: 'Tag went on',
              date: lateSwap,
              timeZone: phoenix,
              isToday: false,
              onChange: () {},
            ),
          ),
        ),
      );
      expect(find.text('2026-07-10'), findsOneWidget);
    });
  });

  group('the zone in plain words', () {
    test('Arizona keeps no daylight saving; Denver does; a sea zone is never '
        'shown by its inverted name', () {
      expect(
        describeTimeZone(phoenix, year: 2026),
        'Phoenix time (UTC−7), no daylight saving',
      );
      expect(
        describeTimeZone('America/Denver', year: 2026),
        'Denver time (UTC−7; UTC−6 with daylight saving)',
      );
      expect(
        describeTimeZone('Etc/GMT+7', year: 2026),
        'UTC−7, sea time zone, no daylight saving',
      );
      expect(
        describeTimeZone('Pacific/Chatham', year: 2026),
        'Chatham time (UTC+12:45; UTC+13:45 with daylight saving)',
      );
    });

    test('the phone\'s own zone is a zone the tz database knows', () {
      expect(FieldTimeZone.isKnown(deviceTimeZone()), isTrue);
    });
  });

  group('the project form', () {
    testWidgets('a new project with no area shows this phone\'s zone, in '
        'words, and says why', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: ProjectSetupScreen())),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('project_time_zone')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text(describeTimeZone(deviceTimeZone()!)),
        findsOneWidget,
      );
      expect(
        find.text(
          "This phone's time zone, because the project has no area yet.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('changing a saved project\'s zone says first that recorded '
        'days stay the same days, and Cancel changes nothing', (tester) async {
      final project = sampleProject(
        id: 'project-1',
        ownerUserId: 'user-owner',
      ).copyWith(timeZone: phoenix);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentProjectProvider.overrideWith((ref) async => project),
          currentUserProvider.overrideWith(
            (ref) async => sampleUser(id: 'user-owner', email: 'owner@x.com'),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(
          Tables.users,
          sampleUser(id: 'user-owner', email: 'owner@x.com').toColumns(),
        );
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: 'user-owner').toColumns(),
        );
        container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
        await container.read(isProjectOwnerProvider(project.projectId).future);
      });
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ProjectSetupScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Phoenix time (UTC−7), no daylight saving'),
        findsOneWidget,
      );
      expect(find.text("This project's time zone."), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('project_time_zone_change')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('time_zone_filter')),
        'Denver',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('time_zone_America/Denver')));
      await tester.pumpAndSettle();
      expect(find.text('Chosen by you.'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'SAVE PROJECT'));
      await tester.pumpAndSettle();
      expect(find.text('Change the time zone?'), findsOneWidget);
      expect(
        find.textContaining('Days already recorded stay the same days.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('"today" on those forms, use the new time zone'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('cancel_time_zone_change')));
      await tester.pumpAndSettle();
      final stored = await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        return (await db.query(Tables.projects)).single['time_zone'];
      });
      expect(stored, phoenix);
    });
  });
}

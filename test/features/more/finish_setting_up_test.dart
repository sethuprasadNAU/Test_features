import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tritrack/features/map/models/offline_region.dart';
import 'package:tritrack/features/more/widgets/finish_setting_up_sheet.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 11.324, item 1 — **"Finish setting up" after creating a project.**
///
/// Michael, reviewing the printed guide (2026-10-02): right after *SAVE
/// PROJECT*, one short sheet with two boxes, both ticked — publish to the
/// server now (only when this phone is signed in) and download offline maps
/// for this area now, with the size shown first. *Later* leaves both on the
/// Pre-Trip Checklist. A member gets the maps half only, once, after their
/// request is accepted.
///
/// The save itself is not driven here — `project_setup_screen_test.dart`
/// explains why a widget test cannot complete one — so the pieces are tested
/// directly, and the whole path is Michael's phone check.
void main() {
  setUp(installFakeSharedPreferences);

  // About 2.2 km × 2.2 km around Flagstaff.
  final project = sampleProject().copyWith(
    bboxMinLat: 35.19,
    bboxMinLon: -111.66,
    bboxMaxLat: 35.21,
    bboxMaxLon: -111.64,
  );

  group('the area download', () {
    test('a project with no area has nothing to download', () {
      final noArea = sampleProject().copyWith(
        bboxMinLat: null,
        bboxMinLon: null,
        bboxMaxLat: null,
        bboxMaxLon: null,
      );
      expect(ProjectAreaDownload.of(noArea), isNull);
    });

    test('the size is estimated from the same tiles the download fetches, '
        'and shown in whole megabytes', () {
      final area = ProjectAreaDownload.of(project)!;
      expect(area.mapTiles, greaterThan(0));
      expect(area.elevationTiles, greaterThan(0));
      expect(
        area.estimatedBytes,
        area.mapTiles * ProjectAreaDownload.bytesPerMapTile +
            area.elevationTiles * ProjectAreaDownload.bytesPerElevationTile,
      );
      expect(area.sizeLabel, matches(RegExp(r'^about \d+ MB$')));
    });

    test('it counts as done only when both map tiles and elevation covering '
        'the whole area finished downloading', () {
      final area = ProjectAreaDownload.of(project)!;
      OfflineRegion region(
        OfflineRegionKind kind, {
        OfflineRegionStatus status = OfflineRegionStatus.complete,
        double grow = 0.01,
      }) => OfflineRegion(
        id: '$kind-$status-$grow',
        kind: kind,
        polygon: [
          LatLng(35.19 - grow, -111.66 - grow),
          LatLng(35.19 - grow, -111.64 + grow),
          LatLng(35.21 + grow, -111.64 + grow),
          LatLng(35.21 + grow, -111.66 - grow),
        ],
        status: status,
        tileTotal: 1,
        tileCompleted: 1,
        sizeBytes: 1,
        createdAt: DateTime(2026, 10, 8),
        updatedAt: DateTime(2026, 10, 8),
      );
      expect(area.isDownloaded(const []), isFalse);
      expect(area.isDownloaded([region(OfflineRegionKind.tiles)]), isFalse,
          reason: 'elevation is half of what the box promised');
      expect(
        area.isDownloaded([
          region(OfflineRegionKind.tiles),
          region(OfflineRegionKind.dem, status: OfflineRegionStatus.partial),
        ]),
        isFalse,
      );
      expect(
        area.isDownloaded([
          region(OfflineRegionKind.tiles, grow: -0.005),
          region(OfflineRegionKind.dem),
        ]),
        isFalse,
        reason: 'a smaller area inside the project does not cover it',
      );
      expect(
        area.isDownloaded([
          region(OfflineRegionKind.tiles),
          region(OfflineRegionKind.dem),
        ]),
        isTrue,
      );
    });
  });

  group('the sheet', () {
    Future<FinishSetupChoice?> open(
      WidgetTester tester, {
      String? publishAs,
      ProjectAreaDownload? maps,
      required Future<void> Function() answer,
    }) async {
      FinishSetupChoice? choice;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  choice = await showFinishSettingUpSheet(
                    context,
                    publishAs: publishAs,
                    maps: maps,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await answer();
      await tester.pumpAndSettle();
      return choice;
    }

    testWidgets('WATCHED RED: both boxes ticked, the size shown, and Start '
        'does both', (tester) async {
      final area = ProjectAreaDownload.of(project)!;
      final choice = await open(
        tester,
        publishAs: 'sam@example.com',
        maps: area,
        answer: () async {
          expect(find.text('Finish setting up'), findsOneWidget);
          expect(find.text('Publish to the server now'), findsOneWidget);
          expect(find.textContaining('sam@example.com'), findsOneWidget,
              reason: 'the account that becomes the owner is named');
          expect(
            find.text(
              'Download offline maps for this area now (${area.sizeLabel})',
            ),
            findsOneWidget,
          );
          final boxes = tester.widgetList<CheckboxListTile>(
            find.byType(CheckboxListTile),
          );
          expect(boxes.map((b) => b.value), [true, true]);
          await tester.tap(find.text('Start'));
        },
      );
      expect(choice!.publish, isTrue);
      expect(choice.downloadMaps, isTrue);
    });

    testWidgets('Later does neither', (tester) async {
      final choice = await open(
        tester,
        publishAs: 'sam@example.com',
        maps: ProjectAreaDownload.of(project),
        answer: () => tester.tap(find.text('Later')),
      );
      expect(choice!.publish, isFalse);
      expect(choice.downloadMaps, isFalse);
    });

    testWidgets('a box can be unticked', (tester) async {
      final choice = await open(
        tester,
        publishAs: 'sam@example.com',
        maps: ProjectAreaDownload.of(project),
        answer: () async {
          await tester.tap(find.text('Publish to the server now'));
          await tester.pump();
          await tester.tap(find.text('Start'));
        },
      );
      expect(choice!.publish, isFalse);
      expect(choice.downloadMaps, isTrue);
    });

    testWidgets('not signed in: no publish box at all — the maps half only, '
        'which is also what a member gets', (tester) async {
      final choice = await open(
        tester,
        maps: ProjectAreaDownload.of(project),
        answer: () async {
          expect(find.text('Publish to the server now'), findsNothing);
          expect(find.byType(CheckboxListTile), findsOneWidget);
          await tester.tap(find.text('Start'));
        },
      );
      expect(choice!.publish, isFalse);
      expect(choice.downloadMaps, isTrue);
    });
  });

  group('a member is offered the maps once', () {
    test('the first time for a project, and never again', () async {
      expect(await MapsOfferedAfterJoining.claim('project-1'), isTrue);
      expect(await MapsOfferedAfterJoining.claim('project-1'), isFalse);
      expect(await MapsOfferedAfterJoining.claim('project-2'), isTrue);
    });
  });
}

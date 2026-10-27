import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/format/coordinate_formatter.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/map/screens/map_screen.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 11.209, acceptance item 4: "the exact string produced for each of
/// the four selection types, in each of the three coordinate formats. That
/// is the deliverable and it is fully assertable without a share sheet."
///
/// Drives the real card's share menu end to end — tap the marker, tap the
/// share icon, tap "Copy coordinates" — and reads back what actually landed
/// on the clipboard, rather than asserting against the private string-
/// building code from inside the same file that would write it.
void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);

  void silenceTileLoadErrors() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  /// Captures every `Clipboard.setData` call — nothing in `flutter_test`
  /// mocks the platform clipboard channel by default.
  List<String> interceptClipboard() {
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    return copied;
  }

  Project pointProject({
    required double lat,
    required double lon,
    required CoordinateFormat format,
  }) =>
      sampleProject(id: 'project-1', ownerUserId: 'user-1').copyWith(
        bboxMinLat: lat,
        bboxMaxLat: lat,
        bboxMinLon: lon,
        bboxMaxLon: lon,
        coordinateFormat: format,
      );

  Future<void> setUpScreen(
    WidgetTester tester, {
    required Project project,
    Observation? observation,
    bool estimate = false,
    bool truthPoint = false,
  }) async {
    silenceTileLoadErrors();
    final user = sampleUser(id: 'user-1', email: 'a@example.com');
    final tag = sampleTag(id: 'tag-1', tagName: 'Coco');
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        currentUserProvider.overrideWith((ref) async => user),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      final tagRepo = await container.read(tagRepositoryProvider.future);
      await userRepo.insert(user);
      await projectRepo.insert(project);
      await tagRepo.insert(tag);
      if (observation != null) {
        final obsRepo =
            await container.read(observationRepositoryProvider.future);
        await obsRepo.insert(observation);
      }
      if (estimate) {
        final estRepo =
            await container.read(estimatedPositionRepositoryProvider.future);
        await estRepo.insert(
          sampleEstimatedPosition(
            projectId: project.projectId,
            tagId: tag.tagId,
          ).copyWith(observationIdsUsed: const []),
        );
      }
      if (truthPoint) {
        final locRepo =
            await container.read(actualTagLocationRepositoryProvider.future);
        await locRepo.insert(
          sampleActualLocation(projectId: project.projectId, tagId: tag.tagId),
        );
      }
      await container
          .read(activeProjectIdProvider.notifier)
          .set(project.projectId);
    });

    await pumpInAppShell(
      tester,
      container: container,
      screen: const MapScreen(),
      tabIndex: 0,
    );
  }

  Future<void> tapMapCenter(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    await tester.pump();
  }

  Future<void> longPressMapCenter(WidgetTester tester) async {
    final map = tester.getRect(find.byKey(const ValueKey('main-map')));
    await tester.longPressAt(map.center);
    await tester.pump();
  }

  /// Opens the selection card's share menu and taps "Copy coordinates".
  Future<void> copyCoordinatesFromCard(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.share_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy coordinates'));
    await tester.pumpAndSettle();
  }

  const formats = [CoordinateFormat.dd, CoordinateFormat.dms, CoordinateFormat.utm];
  const lat = 35.19321;
  const lon = -111.61789;

  for (final format in formats) {
    testWidgets('bearing card: Copy coordinates in ${format.name}', (tester) async {
      final copied = interceptClipboard();
      final observation = sampleObservation(
        id: 'obs-1',
        projectId: 'project-1',
        userId: 'user-1',
        tagId: 'tag-1',
        sessionId: null,
        latitude: lat,
        longitude: lon,
      ).copyWith(trueNorthBearing: 72, magneticBearing: 72);
      await setUpScreen(
        tester,
        project: pointProject(lat: lat, lon: lon, format: format),
        observation: observation,
      );
      await tapMapCenter(tester);
      await copyCoordinatesFromCard(tester);

      expect(copied, [CoordinateFormatter.format(lat, lon, format)]);
    });

    testWidgets('estimate card: Copy coordinates in ${format.name}', (tester) async {
      final copied = interceptClipboard();
      await setUpScreen(
        tester,
        project: pointProject(lat: 35.195, lon: -111.615, format: format),
        estimate: true,
      );
      await tapMapCenter(tester);
      await copyCoordinatesFromCard(tester);

      expect(copied, [CoordinateFormatter.format(35.195, -111.615, format)]);
    });

    testWidgets('truth point card: Copy coordinates in ${format.name}', (tester) async {
      final copied = interceptClipboard();
      await setUpScreen(
        tester,
        project: pointProject(lat: 35.196, lon: -111.616, format: format),
        truthPoint: true,
      );
      await tapMapCenter(tester);
      await copyCoordinatesFromCard(tester);

      expect(copied, [CoordinateFormatter.format(35.196, -111.616, format)]);
    });

    testWidgets('free point card: Copy coordinates in ${format.name}', (tester) async {
      final copied = interceptClipboard();
      await setUpScreen(
        tester,
        project: pointProject(lat: 35.19, lon: -111.61, format: format),
      );
      await longPressMapCenter(tester);
      await copyCoordinatesFromCard(tester);

      expect(copied, [CoordinateFormatter.format(35.19, -111.61, format)]);
    });
  }

  testWidgets('a free point offers no "Copy for TriTrack"', (tester) async {
    await setUpScreen(
      tester,
      project: pointProject(lat: 35.19, lon: -111.61, format: CoordinateFormat.dd),
    );
    await longPressMapCenter(tester);
    await tester.tap(find.byIcon(Icons.share_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Copy for TriTrack'), findsNothing);
  });

  testWidgets('a bearing offers "Copy for TriTrack"', (tester) async {
    final observation = sampleObservation(
      id: 'obs-1',
      projectId: 'project-1',
      userId: 'user-1',
      tagId: 'tag-1',
      sessionId: null,
      latitude: lat,
      longitude: lon,
    ).copyWith(trueNorthBearing: 72, magneticBearing: 72);
    await setUpScreen(
      tester,
      project: pointProject(lat: lat, lon: lon, format: CoordinateFormat.dd),
      observation: observation,
    );
    await tapMapCenter(tester);
    await tester.tap(find.byIcon(Icons.share_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Copy for TriTrack'), findsOneWidget);
  });
}

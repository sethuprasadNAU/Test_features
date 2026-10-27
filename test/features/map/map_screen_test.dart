import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/computation_status_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/providers/recordings_revision_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/core/theme/design_tokens.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/actual_tag_location.dart';
import 'package:tritrack/data/models/estimated_position.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/core/providers/navigation_target_provider.dart';
import 'package:tritrack/features/map/screens/map_screen.dart';
import 'package:tritrack/features/map/widgets/elevation_profile_panel.dart';
import 'package:tritrack/features/map/services/tile_sources.dart';
import 'package:tritrack/features/map/widgets/map_furniture.dart';
import 'package:tritrack/widgets/segmented_toggle.dart';
import 'package:tritrack/widgets/tag_color_swatch.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart' show usePhoneGeometry;
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/roboto_font.dart';
import '../../support/text_scale_probe.dart';

/// Task 9.3: `MapScreen` (2,796 lines) was the only major screen with no
/// test file at all — flagged in the backlog, then reconfirmed by tasks 4.4,
/// 8.2, and 8.5, each of which shipped map behavior verified by code
/// inspection only. This file's smoke test closed that gap; task 9.4 (the
/// groups below) adds targeted regression coverage for the four behaviors
/// that shipped that way: per-tag coloring, the tag-keyed legend, the live
/// tag-color-update fix, and 8.2's Edit-button author gate.
///
/// Modeled on `record_position_preview_screen_test.dart`, with one key
/// difference: that screen never triggers a repository-backed provider it
/// can't pre-resolve from the test, so its `pumpWidget` call sits outside
/// `tester.runAsync`. `MapScreen` immediately watches the private,
/// unoverridable `_mapDataProvider`, which does real `sqflite_common_ffi`
/// queries through an isolate round trip — a Future that never resolves
/// under the fake-async pump clock no matter when it's kicked off, so the
/// *entire* first build (pumpWidget + settling pumps) has to run inside
/// `runAsync`, matching `app_boot_helper.dart`'s pattern rather than
/// `record_position_preview_screen_test.dart`'s.
void main() {
  setUp(installFakeSharedPreferences);
  // Task 11.69. `MapScreen`'s tile cache reaches for
  // `getApplicationSupportDirectory`, and in a widget test there is no plugin
  // behind that channel on any platform — the same reason
  // `tile_cache_test.dart`, `download_manager_test.dart` and
  // `offline_tile_downloader_test.dart` each install this fake.
  //
  // It only bites here in the tests that use `tester.runAsync`, because that
  // is what lets the cache's real async work actually proceed instead of
  // sitting frozen behind the fake-async clock. Whether it gets far enough to
  // throw before the test ends is a race, which is why this file was green on
  // the development machine and on two of three CI runs, and then produced 48
  // `MissingPluginException`s on the third. A test that passes because a
  // background failure did not finish in time is not passing for a reason.
  setUp(installFakePathProvider);

  /// Seeds a project plus whichever tags/links/recordings a test needs, all
  /// through the real repositories — `_mapDataProvider` is private and can't
  /// be overridden or pre-fetched from here, so seeding real rows for it to
  /// read is the task's explicitly preferred approach over stubbing it.
  Future<ProviderContainer> readyContainer(
    WidgetTester tester, {
    required Project project,
    List<dynamic> overrides = const [],
    List<User> users = const [],
    List<Tag> tags = const [],
    /// Tags seeded and then **removed from the project** — a tombstone on
    /// the project's own tag row since task 11.219. The rows stay, so a
    /// bearing that names one still resolves; the map's legend does not
    /// list them, which is the case `_tagColor`'s fallback exists for.
    List<Tag> removedTags = const [],
    List<Observation> observations = const [],
    List<EstimatedPosition> estimates = const [],
    List<ActualTagLocation> tagLocations = const [],

    /// **Whether to give each seeded collar an animal of its own** — task
    /// 11.243. True by default because the map draws a collar in the colour
    /// of the animal wearing it, and a fixture with no animals would make
    /// every ray grey, which would be measuring the fixture rather than the
    /// map. A test that is *about* the links writes its own and passes false.
    bool linkAnimals = true,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      final tagRepo = await container.read(tagRepositoryProvider.future);
      final obsRepo = await container.read(observationRepositoryProvider.future);
      final estRepo = await container.read(estimatedPositionRepositoryProvider.future);
      final locRepo = await container.read(actualTagLocationRepositoryProvider.future);

      for (final u in users.isEmpty ? [sampleUser()] : users) {
        await userRepo.insert(u);
      }
      await projectRepo.insert(project);
      // Task 11.237: every row seeded below is written *as* the user its
      // audit column names, and a repository now refuses somebody the device
      // can see is not on the project. The fixture's users and its stamp
      // (`sampleSync` says `user-1`) are all contributors here; a test that
      // wants a different role for one of them changes that row's `role`.
      await seedContributors(
        (await container.read(appDatabaseProvider.future)).raw,
        projectId: project.projectId,
        userIds: [for (final u in users) u.userId, 'user-1'],
      );
      // **Task 11.243: an animal per seeded collar, and the dated link.**
      // `TagRepository.insert` did this itself at schema v16 and does not
      // any more — a tag is equipment and invents no animal. The map draws a
      // collar in the colour of the animal wearing it, so a fixture with no
      // animals would make every ray on every map test grey, which would be
      // measuring the fixture rather than the map.
      final individualRepo = await container.read(
        individualRepositoryProvider.future,
      );
      final deploymentRepo = await container.read(
        deploymentRepositoryProvider.future,
      );
      for (final t in [...tags, ...removedTags]) {
        await tagRepo.insert(t);
        if (!linkAnimals) continue;
        await individualRepo.insert(
          sampleIndividual(
            id: 'animal-${t.tagId}',
            projectId: t.projectId,
            name: t.tagName,
            colorHex: t.colorHex,
          ),
        );
        await deploymentRepo.link(
          sampleDeployment(
            id: 'deployment-${t.tagId}',
            projectId: t.projectId,
            tagId: t.tagId,
            individualId: 'animal-${t.tagId}',
          ),
        );
      }
      for (final t in removedTags) {
        await tagRepo.removeFromProject(
          t.tagId,
          projectId: t.projectId,
          actor: const MutationActor.replication('map test seed'),
        );
      }
      for (final o in observations) {
        await obsRepo.insert(o);
      }
      for (final e in estimates) {
        await estRepo.insert(e);
      }
      for (final l in tagLocations) {
        await locRepo.insert(l);
      }

      await container.read(activeProjectIdProvider.notifier).set(project.projectId);
    });

    return container;
  }

  /// The whole first build runs inside `runAsync` (see the file doc above)
  /// so `_mapDataProvider`'s real isolate-backed query has a chance to
  /// resolve. Deliberately plain `pump()` calls, never `pumpAndSettle()`:
  /// `map_screen.dart:371`'s `TileLayer` issues real network image requests
  /// through `CachedTileProvider` that never resolve under `flutter test`,
  /// which would spin a settle loop forever — same reasoning as
  /// `offline_data_map_screen_test.dart`.
  Future<void> pumpScreen(
    WidgetTester tester,
    ProviderContainer container, {
    double textScale = 1.0,
  }) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const MapScreen(),
            builder: textScale == 1.0
                ? null
                : (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(textScale)),
                      child: child ?? const SizedBox.shrink(),
                    ),
          ),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });
  }

  /// The map's toolbar icon row overflows the default 800x600 test surface —
  /// same fix Phase 4's `_TagEditDialog` tests needed for a tall dialog. The
  /// Layers & Filters sheet's `ListView(children: ...)` only builds children
  /// within its viewport/cache extent, so a test that needs to reach the
  /// TIME WINDOW section (past LAYERS/VIEWSHED TOOLS/TAGS) needs enough
  /// height that `DraggableScrollableSheet`'s `initialChildSize` fraction of
  /// it fits everything without scrolling — hence the taller `height` some
  /// callers pass.
  void useWideSurface(WidgetTester tester, {double height = 1600}) {
    tester.view.physicalSize = Size(1200, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openLayersSheet(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Layers & filters'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  Future<void> tapSwitch(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(SwitchListTile, label));
    await tester.pump();
  }

  Future<void> tapChip(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(ChoiceChip, label));
    await tester.pump();
  }

  Future<void> tapTagCheckbox(WidgetTester tester, String title) async {
    await tester.tap(find.widgetWithText(CheckboxListTile, title));
    await tester.pump();
  }

  /// L-16 (task 10.95): a fixed real-time delay races `_mapDataProvider`'s
  /// isolate-backed sqflite query, which is serialized against every other
  /// test file's own `sqflite_common_ffi` traffic through that plugin's
  /// single process-wide background isolate — fine in isolation, but under
  /// full-suite concurrency the query occasionally takes longer than any
  /// fixed wait, which is exactly the ~1/3 failure rate measured. Poll for
  /// the expected state instead of sleeping for a guessed duration; must be
  /// called inside `runAsync` so `Future<void>.delayed` runs on the real
  /// clock, matching `pumpScreen`'s reasoning above.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
    Duration step = const Duration(milliseconds: 50),
  }) async {
    // `condition` reads widgets that are absent while `_mapDataProvider`
    // is mid-reload (`dataAsync.when(loading: ...)` swaps the whole map
    // for a spinner) — treat that as "not yet" rather than a test error.
    bool conditionMet() {
      try {
        return condition();
      } on StateError {
        return false;
      } on FlutterError {
        return false;
      }
    }

    final deadline = DateTime.now().add(timeout);
    while (!conditionMet()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TestFailure('pumpUntil: condition not met within $timeout');
      }
      await Future<void>.delayed(step);
      await tester.pump();
    }
  }

  /// Taps the map's own center to select whatever recording sits there (see
  /// the `Edit-button author gate` group below for how the camera is made to
  /// land exactly on it). flutter_map's tap detector
  /// (`PositionedTapDetector2`) waits out a real 250ms double-tap
  /// disambiguation window — via a `Stream.timeout` created during the first
  /// build, which ran inside `pumpScreen`'s `runAsync` and so is bound to the
  /// real zone — before firing `MapOptions.onTap`. A tap performed outside
  /// `runAsync` (plain `tester.tapAt` + fake-clock `pump(duration)`) never
  /// resolves that timeout and the map silently never selects anything, no
  /// exception, no timeout — the same real-vs-fake-zone split as
  /// `_mapDataProvider`, just surfacing in flutter_map's gesture stack
  /// instead of a repository query.
  Future<void> tapMapCenter(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
  }

  testWidgets('with a seeded project, tag, and observation, MapScreen pumps and renders without throwing',
      (tester) async {
    useWideSurface(tester);

    final project = sampleProject();
    final tag = sampleTag();
    final container = await readyContainer(
      tester,
      project: project,
      tags: [tag],
      observations: [
        sampleObservation(projectId: project.projectId, tagId: tag.tagId, sessionId: null),
      ],
    );
    await pumpScreen(tester, container);

    expect(tester.takeException(), isNull);
    expect(find.byType(MapScreen), findsOneWidget);
    expect(find.byType(FlutterMap), findsOneWidget);
  });

  group('map-type selector has no panel and a blurred halo behind it (task 11.190)', () {
    testWidgets('SegmentedToggle is not wrapped in a solid-color Container panel', (tester) async {
      useWideSurface(tester);
      final project = sampleProject();
      final container = await readyContainer(tester, project: project);
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      // Task 11.106 wrapped the toggle in a `Container` with a
      // `BoxDecoration(color: scheme.surface, ...)` panel. Michael asked
      // (task 11.190) for that panel gone so the map shows through behind
      // the unselected options. Assert there is no ancestor `Container`
      // between the toggle and the `Positioned` that places it — a
      // `DecoratedBox`/`Container` there would be exactly the reintroduced
      // panel.
      final toggleFinder = find.byType(SegmentedToggle<TileCategory>).first;
      final containerAncestors = find.ancestor(
        of: toggleFinder,
        matching: find.byWidgetPredicate((w) {
          if (w is! Container) return false;
          final decoration = w.decoration;
          return decoration is BoxDecoration && decoration.color != null;
        }),
      );
      expect(
        containerAncestors,
        findsNothing,
        reason: 'a solid-color Container ancestor is the panel task 11.190 removed',
      );
    });

    testWidgets('a blurred, darkened silhouette of the toggle sits behind the real one', (tester) async {
      useWideSurface(tester);
      final project = sampleProject();
      final container = await readyContainer(tester, project: project);
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      // Two `SegmentedToggle`s: the real, on-top control, and the
      // blurred/darkened halo clone behind it that keeps the unselected
      // labels legible over satellite imagery and terrain shading without a
      // background panel.
      expect(find.byType(SegmentedToggle<TileCategory>), findsNWidgets(2));
      expect(find.byType(ImageFiltered), findsWidgets);
      expect(
        find.ancestor(
          of: find.byType(SegmentedToggle<TileCategory>),
          matching: find.byType(ColorFiltered),
        ),
        findsOneWidget,
        reason: 'one of the two toggles must be flattened to a solid silhouette to form the halo',
      );
    });

    testWidgets(
        'unselected label color follows the basemap: white over terrain/street, dark over satellite',
        (tester) async {
      useWideSurface(tester);
      final project = sampleProject();
      final container = await readyContainer(tester, project: project);
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      // Two copies of each label exist (the halo clone and the real, on-top
      // one) — the halo copy is flattened to a solid silhouette by
      // `ColorFiltered`, so its own text color is irrelevant. Read the color
      // off the copy that is *not* under a `ColorFiltered` ancestor.
      Color? realLabelColor(String label) {
        for (final element in find.text(label).evaluate()) {
          if (element.findAncestorWidgetOfExactType<ColorFiltered>() == null) {
            return (element.widget as Text).style?.color;
          }
        }
        return null;
      }

      // The default basemap is Terrain (task 11.190, Michael 2026-09-07):
      // unselected 'Street' and 'Satellite' read white so they hold up over
      // terrain's contour shading and street-map linework, blended with the
      // dark halo behind them.
      expect(realLabelColor('Street'), Colors.white);
      expect(realLabelColor('Satellite'), Colors.white);

      // Stack paints `topToggle` last (on top), so its subtree is the
      // second `SegmentedToggle` in traversal order — tap through it
      // specifically rather than the halo copy underneath, which is
      // excluded from hit-testing by its own `IgnorePointer` anyway.
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedToggle<TileCategory>).last,
          matching: find.text('Satellite'),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Over satellite imagery the unselected labels stay the original dark
      // `onSurface` color ("black, as is now" — Michael's own words).
      final scheme = Theme.of(tester.element(find.byType(MapScreen))).colorScheme;
      expect(realLabelColor('Terrain'), scheme.onSurface);
      expect(realLabelColor('Street'), scheme.onSurface);
    });
  });

  group('per-tag coloring (task 4.4)', () {
    testWidgets(
        'two tags with distinct colors produce distinguishably-colored rays, '
        'estimates, and tag locations, with a dangling tag_id falling back '
        'instead of crashing', (tester) async {
      useWideSurface(tester);

      final project = sampleProject();
      final tagA = sampleTag(id: 'tag-a', tagName: 'Alpha', colorHex: TagColorPalette.colorForIndex(0));
      final tagB = sampleTag(id: 'tag-b', tagName: 'Bravo', colorHex: TagColorPalette.colorForIndex(1));
      // **Removed from the project** — the case `_tagColor`'s fallback
      // exists for. It used to be "a tag with no `Project_Tags` link"; since
      // task 11.219 a bearing and its tag are in one project by
      // construction, so the only way the map can hold a bearing whose tag
      // is not on its legend is a tag the project took out. The row stays
      // (a tombstone, never a hard delete), so the bearing still resolves.
      final danglingTag =
          sampleTag(id: 'tag-dangling', tagName: 'Dangling', colorHex: TagColorPalette.colorForIndex(2));

      // Distinct coordinates per ray — `colorForRay` below looks a polyline
      // up by its origin point, which only works if each ray has one.
      final rayA = sampleObservation(
        id: 'obs-a',
        projectId: project.projectId,
        tagId: tagA.tagId,
        sessionId: null,
        latitude: 35.10,
      );
      final rayB = sampleObservation(
        id: 'obs-b',
        projectId: project.projectId,
        tagId: tagB.tagId,
        sessionId: null,
        latitude: 35.20,
      );
      final rayDangling = sampleObservation(
        id: 'obs-dangling',
        projectId: project.projectId,
        tagId: danglingTag.tagId,
        sessionId: null,
        latitude: 35.30,
      );

      final container = await readyContainer(
        tester,
        project: project,
        tags: [tagA, tagB],
        removedTags: [danglingTag],
        observations: [rayA, rayB, rayDangling],
        estimates: [sampleEstimatedPosition(id: 'est-a', projectId: project.projectId, tagId: tagA.tagId)],
        tagLocations: [sampleActualLocation(id: 'loc-b', projectId: project.projectId, tagId: tagB.tagId)],
      );
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      final polylines = tester.widget<PolylineLayer>(find.byType(PolylineLayer)).polylines;
      Color colorForRay(Observation o) => polylines
          .firstWhere((p) => p.points.first.latitude == o.latitude && p.points.first.longitude == o.longitude)
          .color;

      expect(colorForRay(rayA), tagColorFromHex(tagA.colorHex));
      expect(colorForRay(rayB), tagColorFromHex(tagB.colorHex));
      // Dangling tag_id (unlinked from the project) falls back to the fixed
      // theme color instead of crashing on the lookup miss.
      expect(colorForRay(rayDangling), DesignTokens.bearingBlueLight);
      expect(colorForRay(rayA), isNot(colorForRay(rayB)));

      // `_EstimateMarker`/`_TagLocationMarker` are private, but the label
      // Text they render carries the tag color directly in its style, so no
      // reflection/private-type access is needed to read it back.
      Color labelColor(String label) => tester.widget<Text>(find.text(label)).style!.color!;

      expect(
        labelColor('Estimate · ${tagA.tagName} · ${tagA.frequencyMhz.toStringAsFixed(3)} MHz'),
        tagColorFromHex(tagA.colorHex),
      );
      expect(
        labelColor('Truth · ${tagB.tagName} · ${tagB.frequencyMhz.toStringAsFixed(3)} MHz'),
        tagColorFromHex(tagB.colorHex),
      );
    });
  });

  /// **Task 11.319 items 1 and 2: an estimated position and a truth point
  /// drawn close together.**
  ///
  /// Found by `/w-30`'s screenshot run at a wide zoom: the two markers were
  /// 13 screen points apart, both said *"Sage · 150.284 MHz"*, and a tap on
  /// the truth point opened the estimate's card. The map's tap radius is 24
  /// points, so at that distance the two overlap almost entirely and the
  /// answer to "which one did the finger mean" has to come from something
  /// better than a coin toss over who is nearer to the center.
  ///
  /// **The fixture puts the map's camera on a device position**, where the
  /// screen moves it to zoom 15 after the first frame (one screen point is
  /// about 3.9 m at this latitude), with the estimate directly north of the
  /// truth point by the ground distance that makes 13 points. The test then
  /// measures the separation from the drawn markers themselves rather than
  /// trusting the arithmetic — and only after one more frame, because the
  /// first one is drawn at the opening zoom and the camera has already moved
  /// on by the time it is built. Measuring that stale frame gave 13 points
  /// between the drawn markers and 26 between the coordinates the tap test
  /// reads, which is how this file first misread the defect.
  group('an estimate and a truth point close together (task 11.319)', () {
    const separationPoints = 13.0;
    const truthLat = 35.196;
    const lon = -111.616;

    Future<({Offset estimate, Offset truth})> pumpCloseMarkers(
      WidgetTester tester, {
      double separation = separationPoints,
    }) async {
      useWideSurface(tester);
      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final tag = sampleTag(tagName: 'Sage', frequencyMhz: 150.284);
      // 28,532 screen points per degree of latitude at zoom 15 and this
      // latitude, so this is 13 points; the measured value is asserted below.
      final estimate = sampleEstimatedPosition(id: 'est-close', tagId: tag.tagId)
          .copyWith(
            latitude: truthLat + separation / 28532,
            longitude: lon,
          );
      final truth = sampleActualLocation(
        id: 'loc-close',
        tagId: tag.tagId,
        tagVersionId: null,
      ).copyWith(latitude: truthLat, longitude: lon);
      final project = sampleProject(ownerUserId: bob.userId).copyWith(
        bboxMinLat: truthLat,
        bboxMaxLat: estimate.latitude,
        bboxMinLon: lon,
        bboxMaxLon: lon,
      );
      final container = await readyContainer(
        tester,
        project: project,
        overrides: [
          currentUserProvider.overrideWith((ref) async => bob),
          gpsPositionProvider.overrideWith(
            (ref) => Stream.value(
              Position(
                latitude: truthLat,
                longitude: lon,
                timestamp: DateTime.utc(2026, 9, 30, 12),
                accuracy: 5,
                altitude: 1500,
                altitudeAccuracy: 4,
                heading: 0,
                headingAccuracy: 5,
                speed: 0,
                speedAccuracy: 0,
              ),
            ),
          ),
        ],
        users: [bob],
        tags: [tag],
        estimates: [estimate.copyWith(projectId: project.projectId)],
        tagLocations: [truth.copyWith(projectId: project.projectId)],
      );
      await pumpScreen(tester, container);
      // One frame more: see the group's comment.
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      });
      // Every tile request fails under `flutter test` (see
      // `isTestHarnessTileFetch` in the GPS group below), and which frame it
      // is reported in is a race — so they are cleared, not asserted absent.
      tester.takeException();

      Rect boxOf(String type) => tester.getRect(
        find.byWidgetPredicate((w) => w.runtimeType.toString() == type),
      );
      // The estimate's dot is centered 9 points below its box's top and the
      // truth point's square 8 (the anchors task 11.100 set).
      final e = boxOf('_EstimateMarker');
      final t = boxOf('_TagLocationMarker');
      final at = (
        estimate: Offset(e.center.dx, e.top + 9),
        truth: Offset(t.center.dx, t.top + 8),
      );
      expect(
        (at.estimate - at.truth).distance,
        closeTo(separation, 0.75),
        reason: 'the fixture is meant to reproduce a $separation-point case',
      );
      return at;
    }

    Future<void> tapAt(WidgetTester tester, Offset where) async {
      await tester.runAsync(() async {
        await tester.tapAt(where);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await tester.pump();
      });
      tester.takeException(); // tile fetches, as above
    }

    /// Called at the end of every test in this group: clears the tile-fetch
    /// errors that arrive after the body has finished. The first test to run
    /// in the group otherwise fails at the end for errors that were reported
    /// a frame late. (Written as a call, not a wrapper around `testWidgets`,
    /// so `app_shell_harness_default_test.dart` still counts every test here
    /// — a wrapper hid five of them behind one.)
    Future<void> drainTileErrors(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });
      tester.takeException();
    }

    final truthCard = find.text('Truth point · Sage · 150.284 MHz');
    final estimateCard = find.text('Estimated position · Sage · 150.284 MHz');

    testWidgets('the two labels say which is which, in words that are not '
        'either card\'s title', (tester) async {
      await pumpCloseMarkers(tester);

      expect(find.text('Estimate · Sage · 150.284 MHz'), findsOneWidget);
      expect(find.text('Truth · Sage · 150.284 MHz'), findsOneWidget);
      expect(
        find.text('Sage · 150.284 MHz'),
        findsNothing,
        reason: 'the old label, identical on both markers',
      );
      // **Deliberately not the cards' own words.** The screenshot harness
      // decides a card is open by looking for its title as text
      // (`readiness.dart`'s `truth-point-panel` condition looks for
      // "Truth point · Sage"), so a label that contained the title would
      // make that check pass with the card closed. Neither card is open here.
      expect(truthCard, findsNothing);
      expect(estimateCard, findsNothing);
      await drainTileErrors(tester);
    });

    testWidgets('a tap on the truth point itself opens the truth point',
        (tester) async {
      final at = await pumpCloseMarkers(tester);

      await tapAt(tester, at.truth);

      expect(truthCard, findsOneWidget);
      expect(estimateCard, findsNothing);
      await drainTileErrors(tester);
    });

    testWidgets('a tap on the estimate itself opens the estimate',
        (tester) async {
      final at = await pumpCloseMarkers(tester);

      await tapAt(tester, at.estimate);

      expect(estimateCard, findsOneWidget);
      expect(truthCard, findsNothing);
      await drainTileErrors(tester);
    });

    /// **The red ones.** The truth point's square is 16 points across, drawn
    /// on top of the estimate's ring. A finger on the edge of the square that
    /// faces the estimate is on the square and can be nearer the estimate's
    /// *point* than the truth point's own, so "nearest point wins" opened the
    /// wrong card for a tap on the thing under the finger. **How wide that
    /// strip is depends on how close the two are: 8 minus half the separation,
    /// so 1.5 points at 13 apart (this file's case) and the whole near half of
    /// the square at 8 apart.** Both are asserted, because the 13-point strip
    /// is real but thin and the 8-point one is where a person would notice.
    testWidgets('a tap anywhere on the truth point\'s drawn square opens the '
        'truth point, including the edge nearest the estimate', (tester) async {
      final at = await pumpCloseMarkers(tester);

      // Straight toward the estimate, 7 points: inside the square (half-width
      // 8), and nearer the estimate's point (6) than the truth point's (7).
      await tapAt(tester, at.truth + const Offset(0, -7));

      expect(truthCard, findsOneWidget);
      expect(estimateCard, findsNothing);
      await drainTileErrors(tester);
    });

    testWidgets('with the two only 8 points apart, the near half of the '
        'truth point\'s square still opens the truth point', (tester) async {
      final at = await pumpCloseMarkers(tester, separation: 8);

      // 5 points toward the estimate: inside the square (half-width 8), and
      // 3 from the estimate's point against 5 from the truth point's own.
      await tapAt(tester, at.truth + const Offset(0, -5));

      expect(truthCard, findsOneWidget);
      expect(estimateCard, findsNothing);
      await drainTileErrors(tester);
    });

    testWidgets('a tap on the estimate\'s ring, outside the square, still '
        'opens the estimate', (tester) async {
      final at = await pumpCloseMarkers(tester);

      // 8 points above the estimate's point: on its 9-point-radius ring and
      // 21 from the truth point, well outside the square.
      await tapAt(tester, at.estimate + const Offset(0, -8));

      expect(estimateCard, findsOneWidget);
      expect(truthCard, findsNothing);
      await drainTileErrors(tester);
    });
  });

  group('tag-keyed legend (task 4.4)', () {
    testWidgets(
        'lists only tags with currently visible elements sorted by name, updates on the '
        'per-tag filter/layer toggles/time window, and hides entirely (not just empty) '
        'once nothing is visible', (tester) async {
      useWideSurface(tester, height: 3200);

      final project = sampleProject();
      final tagZulu = sampleTag(id: 'tag-zulu', tagName: 'Zulu', colorHex: TagColorPalette.colorForIndex(0));
      final tagAlpha = sampleTag(id: 'tag-alpha', tagName: 'Alpha', colorHex: TagColorPalette.colorForIndex(1));

      final container = await readyContainer(
        tester,
        project: project,
        tags: [tagZulu, tagAlpha],
        estimates: [
          sampleEstimatedPosition(id: 'est-zulu', projectId: project.projectId, tagId: tagZulu.tagId),
        ],
        tagLocations: [
          sampleActualLocation(id: 'loc-alpha', projectId: project.projectId, tagId: tagAlpha.tagId),
        ],
      );
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      List<(Color, String)> rows() {
        final finder = find.byType(MapLegendCard);
        if (finder.evaluate().isEmpty) return const [];
        return tester.widget<MapLegendCard>(finder).rows;
      }

      await openLayersSheet(tester);
      await tapSwitch(tester, 'Legend');

      // Alphabetical, not insertion/tag-id order.
      expect(rows().map((r) => r.$2).toList(), ['Alpha', 'Zulu']);
      // Nothing computed a viewshed, so its row is never appended.
      expect(rows().any((r) => r.$2 == 'Viewshed'), isFalse);

      // Hiding Zulu via the per-tag visibility filter drops it live.
      await tapTagCheckbox(tester, '${tagZulu.frequencyMhz.toStringAsFixed(3)} MHz · Zulu');
      expect(rows().map((r) => r.$2).toList(), ['Alpha']);

      // Re-showing it restores the row.
      await tapTagCheckbox(tester, '${tagZulu.frequencyMhz.toStringAsFixed(3)} MHz · Zulu');
      expect(rows().map((r) => r.$2).toList(), ['Alpha', 'Zulu']);

      // Both tags' only visible elements are fixture timestamps well in the
      // past — filtering to "Today" empties the legend without touching any
      // toggle, proving it respects the active time window too.
      await tapChip(tester, 'Today');
      expect(rows(), isEmpty);
      await tapChip(tester, 'All time');
      expect(rows().map((r) => r.$2).toList(), ['Alpha', 'Zulu']);

      // Turning off the layer Alpha's only visible element belongs to drops
      // just that tag.
      await tapSwitch(tester, 'Actual tag locations');
      expect(rows().map((r) => r.$2).toList(), ['Zulu']);

      // Turning off Zulu's layer too empties the legend entirely — and the
      // card itself disappears rather than rendering empty.
      await tapSwitch(tester, 'Estimated positions');
      expect(rows(), isEmpty);
      expect(find.byType(MapLegendCard), findsNothing);
    });
  });

  group('filtering by animal (task 11.247, replacing 11.241)', () {
    testWidgets(
        "an animal's checkbox filters per ray, by whichever deployment "
        'covers the moment it was taken — not by every collar she has ever '
        'worn — and a ray with no covering deployment stays visible and '
        'unattributed', (tester) async {
      useWideSurface(tester, height: 3200);

      final project = sampleProject();
      final marie2025 = sampleTag(
        id: 'marie-2025',
        tagName: 'Marie',
        frequencyMhz: 160.321,
        colorHex: TagColorPalette.colorForIndex(0),
      );
      final marie2026 = sampleTag(
        id: 'marie-2026',
        tagName: 'Marie',
        frequencyMhz: 160.523,
        colorHex: TagColorPalette.colorForIndex(0),
      );
      final orphan = sampleTag(
        id: 'orphan',
        tagName: 'Nobody',
        frequencyMhz: 148.0,
        colorHex: TagColorPalette.colorForIndex(2),
      );

      final duringFirstDeployment = sampleEstimatedPosition(
        id: 'est-1',
        projectId: project.projectId,
        tagId: marie2025.tagId,
      ).copyWith(
        timestampLocal: DateTime(2025, 6, 1),
        timestampUtc: DateTime.utc(2025, 6, 1),
      );
      final duringSecondDeployment = sampleEstimatedPosition(
        // Default fixture timestamp (2026-07-16) already falls inside
        // marie2026's open-ended deployment.
        id: 'est-2',
        projectId: project.projectId,
        tagId: marie2026.tagId,
      );
      final unaffiliated = sampleEstimatedPosition(
        id: 'est-3',
        projectId: project.projectId,
        tagId: orphan.tagId,
      );
      // The collar that "fell in a creek and kept transmitting": still
      // named marie-2025, but taken after her deployment on it ended and
      // before anyone else's began — no deployment covers this moment, so
      // design §2 says it belongs to nobody.
      final afterCollarCameOff = sampleEstimatedPosition(
        id: 'est-4',
        projectId: project.projectId,
        tagId: marie2025.tagId,
      ).copyWith(
        timestampLocal: DateTime(2026, 3, 1),
        timestampUtc: DateTime.utc(2026, 3, 1),
      );

      final container = await readyContainer(
        tester,
        project: project,
        tags: [marie2025, marie2026, orphan],
        // This test is about the links, so it writes its own.
        linkAnimals: false,
        estimates: [
          duringFirstDeployment,
          duringSecondDeployment,
          unaffiliated,
          afterCollarCameOff,
        ],
      );
      // Both of Marie's collars on one animal; the third collar on none.
      // **Written as dated links** (task 11.243), sequential because the
      // interlock forbids one animal wearing two at once.
      const marie = 'marie';
      await tester.runAsync(() async {
        final individualRepo = await container.read(
          individualRepositoryProvider.future,
        );
        await individualRepo.insert(
          sampleIndividual(id: marie, projectId: project.projectId),
        );
        final deploymentRepo = await container.read(
          deploymentRepositoryProvider.future,
        );
        await deploymentRepo.link(
          sampleDeployment(
            id: 'd-2025',
            projectId: project.projectId,
            tagId: 'marie-2025',
            individualId: marie,
            attachedDate: DateTime.utc(2025, 1, 1),
            removedDate: DateTime.utc(2026, 1, 1),
          ),
        );
        await deploymentRepo.link(
          sampleDeployment(
            id: 'd-2026',
            projectId: project.projectId,
            tagId: 'marie-2026',
            individualId: marie,
            attachedDate: DateTime.utc(2026, 4, 1),
          ),
        );
      });
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      // Two collars share one tag name ("Marie") but not one frequency, so
      // the label under each estimate marker names which collar it is on —
      // and, since est-1 and est-4 are both on marie-2025, how many markers
      // carry that label is how many of that collar's rays are currently
      // drawn.
      await openLayersSheet(tester);

      final animalBox = find.byKey(ValueKey('map_filter_animal_$marie'));
      expect(animalBox, findsOneWidget);
      expect(find.text('TAGS WITH NO ANIMAL'), findsOneWidget);
      expect(find.byKey(const ValueKey('map_filter_tag_orphan')), findsOneWidget);
      // Her collars sit under her, indented past her own checkbox.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('map_filter_tag_marie-2025'))).dy,
        greaterThan(tester.getTopLeft(animalBox).dy),
      );
      // A plain checkbox, not the old tristate — an animal's own visibility
      // no longer depends on how many of her collars happen to be hidden.
      expect(tester.widget<CheckboxListTile>(animalBox).tristate, isFalse);
      expect(tester.widget<CheckboxListTile>(animalBox).value, isTrue);

      // With Marie shown (the default), both her attributed estimates are
      // drawn — est-1 (160.321) and est-2 (160.523) — plus the orphan's
      // (148.000) and the one taken after her collar came off (also
      // 160.321, alongside est-1).
      expect(find.text('Estimate · Marie · 160.321 MHz'), findsNWidgets(2));
      expect(find.text('Estimate · Marie · 160.523 MHz'), findsOneWidget);
      expect(find.text('Estimate · Nobody · 148.000 MHz'), findsOneWidget);

      await tester.tap(animalBox);
      await tester.pump();

      // Unchecking her hides exactly the ray a deployment actually covers
      // on each collar — est-1, whose interval names her, and est-2 — but
      // never the unaffiliated collar, and never the orphaned ray her own
      // collar (marie-2025) produced after she stopped wearing it: one of
      // the two 160.321 markers survives.
      expect(find.text('Estimate · Marie · 160.321 MHz'), findsOneWidget);
      expect(find.text('Estimate · Marie · 160.523 MHz'), findsNothing);
      expect(find.text('Estimate · Nobody · 148.000 MHz'), findsOneWidget);
    });
  });

  group('ray colour follows the moment, not the collar\'s current owner '
      '(task 11.248, Michael, 2026-09-15)', () {
    testWidgets(
        'a bearing recorded while a collar was on one animal keeps that '
        "animal's colour after the collar moves to another", (tester) async {
      useWideSurface(tester);

      final project = sampleProject();
      final tag = sampleTag(id: 'collar', tagName: '1');
      final marie = sampleIndividual(
        id: 'marie',
        projectId: project.projectId,
        name: 'Marie',
        colorHex: TagColorPalette.colorForIndex(0),
      );
      final kea = sampleIndividual(
        id: 'kea',
        projectId: project.projectId,
        name: 'Kea',
        colorHex: TagColorPalette.colorForIndex(1),
      );
      final oldBearing = sampleObservation(
        id: 'obs-old',
        projectId: project.projectId,
        tagId: tag.tagId,
        sessionId: null,
      ).copyWith(
        timestampUtc: DateTime.utc(2026, 1, 15),
        timestampLocal: DateTime(2026, 1, 15),
      );

      final container = await readyContainer(
        tester,
        project: project,
        tags: [tag],
        // This test writes its own links, on purpose.
        linkAnimals: false,
        observations: [oldBearing],
      );
      await tester.runAsync(() async {
        final individualRepo = await container.read(individualRepositoryProvider.future);
        final deploymentRepo = await container.read(deploymentRepositoryProvider.future);
        await individualRepo.insert(marie);
        await individualRepo.insert(kea);
        // Marie wore this collar when the bearing above was taken, and no
        // longer does — moved to Kea today, the ordinary same-day handover.
        await deploymentRepo.link(
          sampleDeployment(
            id: 'd-marie',
            projectId: project.projectId,
            tagId: 'collar',
            individualId: 'marie',
            attachedDate: DateTime.utc(2026, 1, 1),
            removedDate: DateTime.now().toUtc(),
          ),
        );
        await deploymentRepo.link(
          sampleDeployment(
            id: 'd-kea',
            projectId: project.projectId,
            tagId: 'collar',
            individualId: 'kea',
            attachedDate: DateTime.now().toUtc(),
          ),
        );
      });
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      final rayColor =
          tester.widget<PolylineLayer>(find.byType(PolylineLayer)).polylines.first.color;
      expect(
        rayColor,
        tagColorFromHex(marie.colorHex),
        reason: "the bearing was taken while the collar was Marie's — moving "
            "it to Kea afterward must not repaint it in Kea's colour",
      );
      expect(rayColor, isNot(tagColorFromHex(kea.colorHex)));

      await openLayersSheet(tester);
      await tapSwitch(tester, 'Legend');
      final legendRows = tester.widget<MapLegendCard>(find.byType(MapLegendCard)).rows;
      expect(
        legendRows,
        contains((tagColorFromHex(marie.colorHex), 'Marie')),
        reason: 'the legend names who the visible bearing was actually about',
      );
    });
  });

  group('a handover day — which animal on the map, through the filter, the '
      'colour and the legend (task 11.251, Michael, 2026-09-15)', () {
    // Michael's exact scenario, as he saw it on his phone: animal Alpha is
    // yellow, Bravo is red, tag 1 on Alpha, tag 2 on Bravo, one bearing on
    // each at 10:00; then tag 2 is moved from Bravo to Alpha the same day,
    // which (§5a) also closes Alpha's tag 1 that day. He saw the tag-1
    // bearing draw **grey** — attributed to nobody — and the tag-2 bearing,
    // recorded on Bravo hours before the swap, draw **yellow**.
    //
    // Two fixtures, because §4a has two rules. **Dates only** is the floor:
    // rule 1 gives the tag-1 bearing back to Alpha, and the tag-2 bearing —
    // inside two whole-day deployments — is *contested* and drawn neutral
    // with a legend row saying so, never resolved by picking. **With a
    // time** on the swap, rule 2 hands the 10:00 bearing to Bravo and
    // nothing is contested.
    //
    // The two bearings are told apart by latitude: a ray starts at its
    // observation's position, so `polyline.points.first.latitude` says which
    // bearing a colour belongs to. (A set of colours would not do — the
    // defect *swapped* the two colours, and a set cannot see a swap.)
    const alphaId = 'alpha';
    const bravoId = 'bravo';
    final alphaColor = tagColorFromHex(TagColorPalette.colorForIndex(0));
    final bravoColor = tagColorFromHex(TagColorPalette.colorForIndex(1));
    final neutral = tagColorFromHex(TagColorPalette.noIndividual);
    final swapDay = DateTime(2026, 9, 15);
    final tenAm = DateTime(2026, 9, 15, 10, 0).toUtc();
    const tag1Lat = 35.10;
    const tag2Lat = 35.30;

    Future<ProviderContainer> seed(
      WidgetTester tester, {
      required DateTime swapEnd,
      required DateTime swapStart,
    }) async {
      final project = sampleProject();
      final tag1 = sampleTag(id: 'tag-1', tagName: 'T1', frequencyMhz: 150.1);
      final tag2 = sampleTag(id: 'tag-2', tagName: 'T2', frequencyMhz: 150.2);
      final container = await readyContainer(
        tester,
        project: project,
        tags: [tag1, tag2],
        linkAnimals: false,
        observations: [
          sampleObservation(
            id: 'obs-tag-1',
            projectId: project.projectId,
            tagId: 'tag-1',
            sessionId: null,
            latitude: tag1Lat,
            timestampUtc: tenAm,
          ),
          sampleObservation(
            id: 'obs-tag-2',
            projectId: project.projectId,
            tagId: 'tag-2',
            sessionId: null,
            latitude: tag2Lat,
            timestampUtc: tenAm,
          ),
        ],
      );
      await tester.runAsync(() async {
        final individualRepo = await container.read(individualRepositoryProvider.future);
        final deploymentRepo = await container.read(deploymentRepositoryProvider.future);
        await individualRepo.insert(sampleIndividual(
          id: alphaId,
          projectId: project.projectId,
          name: 'Alpha',
          colorHex: TagColorPalette.colorForIndex(0),
        ));
        await individualRepo.insert(sampleIndividual(
          id: bravoId,
          projectId: project.projectId,
          name: 'Bravo',
          colorHex: TagColorPalette.colorForIndex(1),
        ));
        // Tag 1 on Alpha since August, closed the day tag 2 arrived (§5a).
        await deploymentRepo.link(sampleDeployment(
          id: 'd-tag1-alpha',
          projectId: project.projectId,
          tagId: 'tag-1',
          individualId: alphaId,
          attachedDate: DateTime(2026, 8, 1),
          removedDate: swapEnd,
        ));
        // Tag 2 on Bravo since August, off today; then on Alpha today.
        await deploymentRepo.link(sampleDeployment(
          id: 'd-tag2-bravo',
          projectId: project.projectId,
          tagId: 'tag-2',
          individualId: bravoId,
          attachedDate: DateTime(2026, 8, 1),
          removedDate: swapEnd,
        ));
        // **Planted past the interlock** (task 11.263). The DATES ONLY
        // fixture is two bare days on the swap day — the pair a build with
        // the one-day allowance wrote, and the one the interlock refuses
        // since design §6a. The map still has to read such a pair honestly
        // (§4a's contested rule governs reads, and nothing migrates it), so
        // it goes straight into the table; the timed fixture would pass
        // `link`, and does so in `deployment_linking_test.dart`.
        await deploymentRepo.insertRow(sampleDeployment(
          id: 'd-tag2-alpha',
          projectId: project.projectId,
          tagId: 'tag-2',
          individualId: alphaId,
          attachedDate: swapStart,
        ).toColumns());
      });
      return container;
    }

    /// Ray colour by the latitude the ray starts at, or null if not drawn.
    Color? rayAt(WidgetTester tester, double latitude) {
      final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
      for (final p in layer.polylines) {
        if ((p.points.first.latitude - latitude).abs() < 1e-6) return p.color;
      }
      return null;
    }

    testWidgets('DATES ONLY: the bearing on the day a collar came off is its '
        "animal's (the grey bearing), and the swapped collar's bearing is "
        'contested — neutral, named in the legend, hidden only when both '
        'candidates are', (tester) async {
      useWideSurface(tester, height: 3200);
      final container = await seed(tester, swapEnd: swapDay, swapStart: swapDay);
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      // COLOUR. Tag 1 came off Alpha today; the 10:00 bearing is hers.
      expect(rayAt(tester, tag1Lat), alphaColor,
          reason: 'removed today means today was still hers — this drew '
              'grey on Michael\'s phone');
      // Tag 2's 10:00 bearing is inside both Bravo's whole day and Alpha's:
      // nobody can say, so the map does not.
      expect(rayAt(tester, tag2Lat), neutral,
          reason: 'contested is drawn in nobody\'s colour — this drew '
              'yellow (Alpha\'s) on Michael\'s phone');
      expect(rayAt(tester, tag2Lat), isNot(alphaColor));
      expect(rayAt(tester, tag2Lat), isNot(bravoColor));

      // LEGEND. Alpha's row for her ray, and a row that says the other one
      // is contested — with the word, because colour carries no meaning on
      // its own in this app and a grey ray with no sentence reads as "collar
      // on nobody", which is a different fact.
      await openLayersSheet(tester);
      await tapSwitch(tester, 'Legend');
      final rows = tester.widget<MapLegendCard>(find.byType(MapLegendCard)).rows;
      expect(rows, contains((alphaColor, 'Alpha')));
      expect(rows, contains((neutral, contestedLegendLabel(['Alpha', 'Bravo']))));
      expect(rows.map((r) => r.$2), isNot(contains('Bravo')),
          reason: 'no ray is unambiguously Bravo\'s today');

      // FILTER. Hiding Alpha hides her ray; the contested one might be
      // Bravo's, and stays until Bravo is hidden too.
      await tester.tap(find.byKey(const ValueKey('map_filter_animal_$alphaId')));
      await tester.pump();
      expect(rayAt(tester, tag1Lat), isNull, reason: 'hers, and she is hidden');
      expect(rayAt(tester, tag2Lat), neutral,
          reason: 'might be Bravo\'s — Alpha\'s checkbox does not own it');
      await tester.tap(find.byKey(const ValueKey('map_filter_animal_$bravoId')));
      await tester.pump();
      expect(rayAt(tester, tag2Lat), isNull,
          reason: 'every candidate hidden, so the contested ray goes too');
    });

    testWidgets('WITH A TIME: the swap at 14:32 gives the 10:00 bearing to '
        'Bravo, nothing is contested, and the filter follows', (tester) async {
      useWideSurface(tester, height: 3200);
      final swapAt = DateTime(2026, 9, 15, 14, 32);
      final container = await seed(tester, swapEnd: swapAt, swapStart: swapAt);
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      expect(rayAt(tester, tag1Lat), alphaColor);
      expect(rayAt(tester, tag2Lat), bravoColor,
          reason: 'recorded at 10:00 on Bravo, hours before the 14:32 swap');

      await openLayersSheet(tester);
      await tapSwitch(tester, 'Legend');
      final rows = tester.widget<MapLegendCard>(find.byType(MapLegendCard)).rows;
      expect(rows, contains((alphaColor, 'Alpha')));
      expect(rows, contains((bravoColor, 'Bravo')));
      expect(rows.map((r) => r.$2).where((n) => n.startsWith('Contested')),
          isEmpty);

      await tester.tap(find.byKey(const ValueKey('map_filter_animal_$alphaId')));
      await tester.pump();
      expect(rayAt(tester, tag1Lat), isNull);
      expect(rayAt(tester, tag2Lat), bravoColor,
          reason: 'Bravo\'s bearing is not hidden with Alpha');
    });
  });

  group('live tag-color update (post-4.4 bug fix, 2026-07-29)', () {
    testWidgets('editing a tag color updates the map live, without an app restart', (tester) async {
      useWideSurface(tester);

      final project = sampleProject();
      final user = sampleUser();
      final tag = sampleTag(colorHex: TagColorPalette.colorForIndex(0));
      final ray = sampleObservation(
        projectId: project.projectId,
        tagId: tag.tagId,
        userId: user.userId,
        sessionId: null,
      );

      final container = await readyContainer(
        tester,
        project: project,
        users: [user],
        tags: [tag],
        observations: [ray],
      );
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      Color currentRayColor() =>
          tester.widget<PolylineLayer>(find.byType(PolylineLayer)).polylines.first.color;

      expect(currentRayColor(), tagColorFromHex(tag.colorHex));

      final newColorHex = TagColorPalette.colorForIndex(1);
      // Same fix as `tag_database_screen.dart`'s tag-edit path: update the
      // row, then bump `recordingsRevisionProvider` — `_mapDataProvider`
      // watches it, so this alone should refresh the already-pumped map with
      // no new `pumpWidget` call, exactly what the original bug got wrong.
      await tester.runAsync(() async {
        final tagRepo = await container.read(tagRepositoryProvider.future);
        await tagRepo.update(
          tag.copyWith(colorHex: newColorHex),
          actor: MutationActor.user(user.userId),
          // Task 11.32: colour is a display key, never versioned, so a
          // recolour asks the person nothing and carries no intent. This is
          // the acceptance case — every record already drawn must change
          // colour immediately, which is what the assertion below checks.
          intent: null,
        );
        container.read(recordingsRevisionProvider.notifier).bump();

        await tester.pump();
        await pumpUntil(tester, () => currentRayColor() == tagColorFromHex(newColorHex));
      });

      expect(tester.takeException(), isNull);
      expect(currentRayColor(), tagColorFromHex(newColorHex));
      expect(currentRayColor(), isNot(tagColorFromHex(tag.colorHex)));
    });
  });

  group('Edit-button author gate (task 8.2)', () {
    // A degenerate (single-point) bbox puts the initial map camera exactly
    // on the observation, so tapping the map widget's own center hits it —
    // same trick `record_position_preview_screen_test.dart` uses to tap
    // "anywhere on the map," just aimed at one specific lat/lon here so the
    // tap lands within `_selectAtPoint`'s 24px hit radius of the ray.
    Project pointProject(String ownerUserId, Observation at) => sampleProject(ownerUserId: ownerUserId).copyWith(
          bboxMinLat: at.latitude,
          bboxMaxLat: at.latitude,
          bboxMinLon: at.longitude,
          bboxMaxLon: at.longitude,
        );

    testWidgets(
        'a replica (observer != current user) shows Edit disabled, with a '
        'reason (task 11.12)', (tester) async {
      useWideSurface(tester);

      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final alice = sampleUser(id: 'user-alice', email: 'alice@example.com');
      final tag = sampleTag();
      // The replica: same shape a faithful save produces — userId is the
      // original observer (Alice), not the receiving/current user (Bob).
      final replica = sampleObservation(
        id: 'obs-replica',
        userId: alice.userId,
        tagId: tag.tagId,
        sessionId: null,
      );
      final project = pointProject(bob.userId, replica);

      final container = await readyContainer(
        tester,
        project: project,
        overrides: [currentUserProvider.overrideWith((ref) async => bob)],
        users: [bob, alice],
        tags: [tag],
        observations: [replica],
      );
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      await tapMapCenter(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Navigate'), findsOneWidget);
      // Task 11.12: rendered disabled with a reason, not absent — a missing
      // button reads as "this observation has no Edit", which is what this
      // replaced.
      expect(find.text('Edit'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.ancestor(
          of: find.text('Edit'),
          matching: find.byType(OutlinedButton),
        )).onPressed,
        isNull,
      );
      expect(
        // Task 11.137: a line under the buttons, not a `Tooltip` a phone
        // never opens.
        find.text('You can only edit or delete observations you recorded yourself.'),
        findsOneWidget,
      );
    });

    testWidgets("the current user's own observation still shows Edit", (tester) async {
      useWideSurface(tester);

      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final tag = sampleTag();
      final own = sampleObservation(
        id: 'obs-own',
        userId: bob.userId,
        tagId: tag.tagId,
        sessionId: null,
      );
      final project = pointProject(bob.userId, own);

      final container = await readyContainer(
        tester,
        project: project,
        overrides: [currentUserProvider.overrideWith((ref) async => bob)],
        users: [bob],
        tags: [tag],
        observations: [own],
      );
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      await tapMapCenter(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Navigate'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.ancestor(
          of: find.text('Edit'),
          matching: find.byType(OutlinedButton),
        )).onPressed,
        isNotNull,
      );
    });

    testWidgets(
        'a viewer (author of their own pre-demotion observation) is still '
        'refused (task 11.12)', (tester) async {
      // The gap the map's Edit gate used to have alongside the Log screen's:
      // it asked authorship only, not role, so a contributor demoted to
      // viewer would still see their own old bearing offered as editable.
      useWideSurface(tester);

      final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
      final viewer = sampleUser(id: 'user-viewer', email: 'viewer@example.com');
      final tag = sampleTag();
      final own = sampleObservation(
        id: 'obs-own',
        userId: viewer.userId,
        tagId: tag.tagId,
        sessionId: null,
      );
      final project = pointProject(owner.userId, own);

      final container = await readyContainer(
        tester,
        project: project,
        overrides: [currentUserProvider.overrideWith((ref) async => viewer)],
        users: [owner, viewer],
        tags: [tag],
        observations: [own],
      );
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        // Demoted: the harness seeded everybody as a contributor.
        await db.update(
          Tables.projectMemberships,
          {'role': ProjectRole.viewer.db},
          where: 'project_id = ? AND user_id = ?',
          whereArgs: [project.projectId, viewer.userId],
        );
      });
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      await tapMapCenter(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Edit'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.ancestor(
          of: find.text('Edit'),
          matching: find.byType(OutlinedButton),
        )).onPressed,
        isNull,
      );
      expect(
        find.text('Viewers cannot edit or delete observations — ask an owner to change your role.'),
        findsOneWidget,
      );
    });

    // **Task 11.92.** The map drew the truth point and the panel showed tag,
    // position and time — everything except the two fields that say what the
    // point means, and with no way to correct or remove it.
    testWidgets('a truth point shows its precision and what was found, and '
        'offers Edit and Delete', (tester) async {
      useWideSurface(tester);

      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final tag = sampleTag();
      final point = sampleActualLocation(
        tagId: tag.tagId,
        foundKind: GroundTruthKind.collarOnly,
        tagVersionId: null,
      );
      final project = sampleProject(ownerUserId: bob.userId).copyWith(
        bboxMinLat: point.latitude,
        bboxMaxLat: point.latitude,
        bboxMinLon: point.longitude,
        bboxMaxLon: point.longitude,
      );

      final container = await readyContainer(
        tester,
        project: project,
        overrides: [currentUserProvider.overrideWith((ref) async => bob)],
        users: [bob],
        tags: [tag],
        tagLocations: [point.copyWith(projectId: project.projectId)],
      );
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      await tapMapCenter(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Truth point'), findsWidgets);
      expect(
        find.textContaining('Tag only · precision ±15 m'),
        findsOneWidget,
        reason: 'a ±3 m animal-and-collar fix and a ±40 m shed collar are '
            'different facts and used to render identically',
      );
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.ancestor(
          of: find.text('Delete'),
          matching: find.byType(OutlinedButton),
        )).onPressed,
        isNotNull,
      );
    });

    /// **Task 11.100.** The marker used to be painted about 28 logical pixels
    /// above the position it stands for — at survey zoom, roughly a hundred
    /// metres of apparent ground offset, on a record whose whole purpose is
    /// being accurate to about ±12 m. The map's own hit test measures from
    /// the real position and accepts 24 pixels, so a tap on the drawn square
    /// selected nothing and the app looked broken.
    ///
    /// The test taps **where the square is drawn**, not the coordinate, so it
    /// fails if the anchor drifts back. `tapMapCenter` above cannot catch
    /// this: it taps the coordinate, which worked throughout the defect.
    testWidgets('tapping the truth-point square where it is drawn selects it',
        (tester) async {
      useWideSurface(tester);

      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final tag = sampleTag();
      final point = sampleActualLocation(tagId: tag.tagId, tagVersionId: null);
      final project = sampleProject(ownerUserId: bob.userId).copyWith(
        bboxMinLat: point.latitude,
        bboxMaxLat: point.latitude,
        bboxMinLon: point.longitude,
        bboxMaxLon: point.longitude,
      );

      final container = await readyContainer(
        tester,
        project: project,
        overrides: [currentUserProvider.overrideWith((ref) async => bob)],
        users: [bob],
        tags: [tag],
        tagLocations: [point.copyWith(projectId: project.projectId)],
      );
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      // Found by run-time type because the marker class is private to
      // `map_screen.dart` — the same way the screenshot harness finds it.
      final marker = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_TagLocationMarker',
      );
      expect(marker, findsOneWidget);

      // The 16px square sits at the top of the 36px column.
      final box = tester.getRect(marker.first);
      // Same runAsync-and-wait shape as `tapMapCenter` — selection settles a
      // frame later than `pumpAndSettle` returns.
      await tester.runAsync(() async {
        await tester.tapAt(Offset(box.center.dx, box.top + 8));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await tester.pump();
      });

      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('Truth point'),
        findsWidgets,
        reason: 'the square is drawn away from the position it stands for, so '
            'a tap on it falls outside the map hit test',
      );
    });
  });

  /// Task 11.259. A season clone carries `observation_ids_used` across on
  /// purpose (task 11.56) — the bearings it names stay in last season's
  /// project. Selecting a carried-over estimate used to say "0 bearings
  /// used" (false: it came from real bearings, just not ones this device
  /// holds) and, worse, dim every other bearing on the map to nothing,
  /// because `highlightIds` held ids that matched no drawn ray.
  group('a carried-over estimate (task 11.259)', () {
    Color colorForRay(WidgetTester tester, Observation o) => tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .expand((layer) => layer.polylines)
        .firstWhere((p) =>
            p.points.first.latitude == o.latitude &&
            p.points.first.longitude == o.longitude)
        .color;

    /// Same shape as `tapMapCenter`, but at the estimate marker's drawn
    /// position rather than the map's center — `_EstimateMarker`'s dot sits
    /// above the map's geo point (`alignment: const Alignment(0, 0.5)`), so
    /// tapping the exact coordinate can miss it the way task 11.100 found
    /// for truth points.
    Future<void> tapEstimateMarker(WidgetTester tester) async {
      final marker = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_EstimateMarker',
      );
      expect(marker, findsOneWidget);
      final box = tester.getRect(marker.first);
      await tester.runAsync(() async {
        await tester.tapAt(Offset(box.center.dx, box.top + 8));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await tester.pump();
      });
    }

    testWidgets(
        'says "computed in an earlier season" instead of "0 bearings used", '
        'and leaves this project\'s own bearings undimmed', (tester) async {
      useWideSurface(tester);

      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final tag = sampleTag();
      final estimate = sampleEstimatedPosition(id: 'est-carried', tagId: tag.tagId)
          .copyWith(observationIdsUsed: const ['obs-elsewhere-1', 'obs-elsewhere-2']);
      // Still in this project, unrelated to the carried estimate's ids. **At
      // the estimate's own coordinates** (task 11.100's marker-offset lesson,
      // one layer out): `chooseMapCameraTarget` frames the camera around
      // every seeded record together, and a separation of even a kilometre
      // between two "recorded" points changes it from a fixed single-point
      // zoom to a fit-to-bounds camera, which pushed both markers off the
      // small test viewport and swamped the test with real tile-fetch
      // failures no assertion here is about.
      final localBearing = sampleObservation(
        id: 'obs-local',
        tagId: tag.tagId,
        sessionId: null,
        latitude: estimate.latitude,
        longitude: estimate.longitude,
      );
      final project = sampleProject(ownerUserId: bob.userId).copyWith(
        bboxMinLat: estimate.latitude,
        bboxMaxLat: estimate.latitude,
        bboxMinLon: estimate.longitude,
        bboxMaxLon: estimate.longitude,
      );

      final container = await readyContainer(
        tester,
        project: project,
        overrides: [currentUserProvider.overrideWith((ref) async => bob)],
        users: [bob],
        tags: [tag],
        observations: [localBearing],
        estimates: [estimate],
      );
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      await tapEstimateMarker(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Estimated position'), findsWidgets);
      expect(find.textContaining('computed in an earlier season'), findsOneWidget);
      expect(find.textContaining('0 bearings used'), findsNothing);

      final rayColor = colorForRay(tester, localBearing);
      expect(
        rayColor.a,
        1.0,
        reason: 'a carried estimate names no local bearing to highlight, so '
            'nothing should be dimmed — the old defect dimmed every ray on '
            'the map because none of the carried ids ever matched one',
      );
    });

    testWidgets(
        'partial carry: counts only the bearing recorded new this season, '
        'not the stored total', (tester) async {
      useWideSurface(tester);

      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final tag = sampleTag();
      final estimate = sampleEstimatedPosition(id: 'est-partial', tagId: tag.tagId)
          .copyWith(observationIdsUsed: const [
        'obs-elsewhere-1',
        'obs-elsewhere-2',
        'obs-new-this-season',
      ]);
      // At the estimate's own coordinates — see the sibling test's comment.
      final newBearing = sampleObservation(
        id: 'obs-new-this-season',
        tagId: tag.tagId,
        sessionId: null,
        latitude: estimate.latitude,
        longitude: estimate.longitude,
      );
      final project = sampleProject(ownerUserId: bob.userId).copyWith(
        bboxMinLat: estimate.latitude,
        bboxMaxLat: estimate.latitude,
        bboxMinLon: estimate.longitude,
        bboxMaxLon: estimate.longitude,
      );

      final container = await readyContainer(
        tester,
        project: project,
        overrides: [currentUserProvider.overrideWith((ref) async => bob)],
        users: [bob],
        tags: [tag],
        observations: [newBearing],
        estimates: [estimate],
      );
      await pumpScreen(tester, container);
      expect(tester.takeException(), isNull);

      await tapEstimateMarker(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('1 bearings used'), findsOneWidget,
          reason: 'only the resolvable bearing is counted — never the '
              'stored list\'s length of 3');
    });

    /// **Task 11.336 item 1.** The estimate card says, in one line, when its
    /// 95% ellipse rests on five or fewer bearings. It reads the **stored**
    /// list's length, not the resolvable count above: how many bearings the
    /// ellipse was computed from is a fact about the estimate, and a season
    /// clone that carried it across did not make it more certain. The words
    /// are written out, not read from the app's constant.
    group('few bearings (task 11.336)', () {
      const caution = 'Few bearings — the 95% ellipse usually understates '
          'the uncertainty. Add bearings if you can. See “How the estimate '
          'is calculated” in the TriTrack guide.';

      Future<void> selectEstimate(
        WidgetTester tester, {
        required int bearings,
        bool hasEllipse = true,
        bool onPhone = false,
        double textScale = 1.0,
      }) async {
        if (onPhone) {
          usePhoneGeometry(tester);
        } else {
          useWideSurface(tester);
        }
        final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
        final tag = sampleTag();
        var estimate = sampleEstimatedPosition(id: 'est-few', tagId: tag.tagId)
            .copyWith(observationIdsUsed: [
          for (var i = 0; i < bearings; i++) 'obs-elsewhere-$i',
        ]);
        if (!hasEllipse) {
          estimate = estimate.copyWith(
            semiMajorAxis: null,
            semiMinorAxis: null,
            rotationAngle: null,
          );
        }
        final project = sampleProject(ownerUserId: bob.userId).copyWith(
          bboxMinLat: estimate.latitude,
          bboxMaxLat: estimate.latitude,
          bboxMinLon: estimate.longitude,
          bboxMaxLon: estimate.longitude,
        );
        final container = await readyContainer(
          tester,
          project: project,
          overrides: [currentUserProvider.overrideWith((ref) async => bob)],
          users: [bob],
          tags: [tag],
          estimates: [estimate],
        );
        await pumpScreen(tester, container, textScale: textScale);
        expect(tester.takeException(), isNull);
        await tapEstimateMarker(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Estimated position'), findsWidgets);
      }

      testWidgets('is on the card at five bearings', (tester) async {
        await selectEstimate(tester, bearings: 5);
        expect(find.text(caution), findsOneWidget);
      });

      testWidgets('is on the card at three bearings', (tester) async {
        await selectEstimate(tester, bearings: 3);
        expect(find.text(caution), findsOneWidget);
      });

      testWidgets('is not on the card at six bearings', (tester) async {
        await selectEstimate(tester, bearings: 6);
        expect(find.textContaining('Few bearings'), findsNothing);
      });

      testWidgets('is not on a card with no ellipse to be unsure about',
          (tester) async {
        await selectEstimate(tester, bearings: 2, hasEllipse: false);
        expect(find.textContaining('Few bearings'), findsNothing);
        expect(find.textContaining('No error ellipse'), findsOneWidget);
      });

      /// **Task 11.338.** The caution now ends by naming the guide page, so
      /// it is longer. The generic clipped-text sweep pumps one bearing per
      /// screen and never shows this line (it needs an ellipse), so it is
      /// measured here: the whole line, at every text size up to the ordinary
      /// Dynamic Type slider's top stop, on the 6.1-inch phone, in Roboto.
      group('is not clipped on the 6.1-inch phone (task 11.338)', () {
        setUpAll(loadRobotoFromSdkCache);

        for (final scale
            in iosTextScalesUpward.where((s) => s <= dynamicTypeSliderCeiling)) {
          testWidgets(textScaleName(scale), (tester) async {
            final overflows = collectLayoutOverflows();
            await selectEstimate(
              tester,
              bearings: 3,
              onPhone: true,
              textScale: scale,
            );
            expect(find.text(caution), findsOneWidget);
            expect(
              clippedTexts(tester)
                  .where((c) => c.text.startsWith('Few bearings')),
              isEmpty,
              reason: 'the few-bearings line is cut short on the Map\'s '
                  'estimate card at ${textScaleName(scale)}',
            );
            // The whole screen, with no exception. Task 11.338 filtered out
            // the estimate's own pin (`_EstimateMarker`), which overflowed by
            // 2-5 px from one notch above the default text size; task 11.332
            // item 6 sized each point marker's box from its label's measured
            // height and removed the filter.
            expect(overflows, isEmpty, reason: overflows.join('; '));
          });
        }
      });
    });
  });

  /// Task 11.95. `/w-02`'s screenshot harness opened the map on a simulator
  /// with a GPS fix and a project open — the ordinary field case — and saw
  /// Riverpod refuse a provider write during build, then, seconds later, an
  /// unhandled asynchronous error it could not account for.
  ///
  /// They are the same error. `_buildBody` called `_maybeAutoComputeViewshed`
  /// during build; that started `_computeViewshedAt`, whose first act was to
  /// move the shared computation-status provider to "Computing viewshed…".
  /// Riverpod refuses a provider write from inside a build. Because
  /// `_computeViewshedAt` is `async` and that write sat *outside* its own
  /// `try`, the refusal did not become a caught failure: it completed an
  /// un-awaited future with an error nobody was listening to.
  ///
  /// So `tester.takeException()` cannot see it — nothing was thrown at the
  /// widget tree — and neither can the field, where the assertion is compiled
  /// out of a release build. What the field got instead was the consequence:
  /// the automatic viewshed never ran, and the bottom progress bar sat at
  /// "Computing viewshed…" for the rest of the session, because the throw
  /// jumped over the `finally` that clears it.
  ///
  /// Both halves are asserted below, and both were confirmed red against the
  /// old code.
  group('opening the map with a GPS fix (task 11.95)', () {
    /// The invented study area the screenshot harness uses, which is where
    /// `/w-02` was standing when it saw this.
    Position seedFix() => Position(
          latitude: 42.7008,
          longitude: -117.3612,
          timestamp: DateTime.utc(2026, 6, 1, 17),
          accuracy: 6.0,
          altitude: 1312.0,
          altitudeAccuracy: 4.0,
          heading: 12.0,
          headingAccuracy: 5.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        );

    /// Every HTTP request under `flutter test` comes back 400, so the map's
    /// own tile fetches report dozens of these however the screen behaves.
    /// They are the test environment, not the app, and filtering them by type
    /// is what lets the assertion below be "no errors" rather than "not too
    /// many errors".
    bool isTestHarnessTileFetch(Object e) => e is NetworkImageLoadException;

    testWidgets('no error escapes the build, and the progress bar does not '
        'stick at "Computing viewshed…"', (tester) async {
      useWideSurface(tester);

      final project = sampleProject();
      final container = await readyContainer(
        tester,
        project: project,
        overrides: [
          gpsPositionProvider.overrideWith((ref) => Stream.value(seedFix())),
        ],
      );

      // The error never reached the widget tree, so it has to be collected
      // where it actually went. Restored before the first `expect`, because
      // leaving `FlutterError.onError` overridden across an assertion makes
      // the binding report a failure of its own instead of this one.
      final escaped = <Object>[];
      final priorOnError = FlutterError.onError;
      FlutterError.onError = (details) => escaped.add(details.exception);

      try {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(theme: AppTheme.light(), home: const MapScreen()),
            ),
          );
          // Long enough for the deferred computation to start, run out of
          // elevation data (there is none in a test) and say so. Polled
          // rather than slept for a guessed duration — same reasoning as
          // `pumpUntil` above.
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (container.read(computationStatusProvider) is! ComputationFailed &&
              DateTime.now().isBefore(deadline)) {
            await tester.pump();
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await tester.pump();
        });
      } finally {
        FlutterError.onError = priorOnError;
      }

      final unexplained =
          escaped.where((e) => !isTestHarnessTileFetch(e)).toList();
      expect(
        unexplained,
        isEmpty,
        reason: 'opening the map with a GPS fix let an error escape the '
            'build: ${unexplained.map((e) => e.toString().split('\n').first)}',
      );

      // The half a release build does not hide. Anything but `Running` is
      // acceptable here — the point is that the computation reported an
      // outcome rather than leaving the bar spinning forever. In this
      // environment there is no elevation data, so the outcome is a failure,
      // and a failure it can state is the correct behaviour.
      expect(
        container.read(computationStatusProvider),
        isNot(isA<ComputationRunning>()),
        reason: 'the viewshed never reported an outcome, so the bottom '
            'progress bar is stuck at "Computing viewshed…"',
      );
    });
  });

  /// Task 11.102: a truth-point panel's Edit/Delete/Navigate row overflowed
  /// by `0.0896` pixels on Michael's real device — a row that fit by
  /// nothing. **Contrary to the development plan's guess, this is not driven
  /// by the tag's name length**: all three button labels ('Edit', 'Delete',
  /// 'Navigate') are fixed strings, not derived from the tag at all — so no
  /// tag name, however long, changes this row's width. What actually starves
  /// it is screen width: the harness's other truth-point tests all call
  /// [useWideSurface] (1200 logical px), which is far wider than any real
  /// phone, and is why nothing here had ever seen this row overflow before a
  /// person held a real device.
  group('truth-point Navigate row overflow (task 11.102)', () {
    testWidgets(
      'the Edit/Delete/Navigate row does not overflow on a narrow phone, '
      'even with an unusually long tag name',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800); // a small Android phone
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
        final tag = sampleTag(tagName: 'Wolverine-Collar-Winter-Study-2026-07');
        final point = sampleActualLocation(tagId: tag.tagId, tagVersionId: null);
        final project = sampleProject(ownerUserId: bob.userId).copyWith(
          bboxMinLat: point.latitude,
          bboxMaxLat: point.latitude,
          bboxMinLon: point.longitude,
          bboxMaxLon: point.longitude,
        );

        final container = await readyContainer(
          tester,
          project: project,
          overrides: [currentUserProvider.overrideWith((ref) async => bob)],
          users: [bob],
          tags: [tag],
          tagLocations: [point.copyWith(projectId: project.projectId)],
        );
        await pumpScreen(tester, container);
        expect(tester.takeException(), isNull);

        await tapMapCenter(tester);
        await tester.pump();

        expect(
          tester.takeException(),
          isNull,
          reason: 'a RenderFlex overflow throws during layout — this is the '
              'regression check for task 11.102',
        );
        expect(find.text('Edit'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
        expect(find.text('Navigate'), findsOneWidget);
      },
    );
  });

  /// Task 11.207 — **the profile is drawn in the colour of the line it is a
  /// profile of**, and this is the coupling that says so.
  ///
  /// Michael, walking with it on 2026-09-09: *"the navigating line on the map
  /// is blue, so the contour line should have the same color"*. It was
  /// `ColorScheme.primary` — the brand green — at both call sites, which is a
  /// colour nobody chose: it matched nothing on the map, on a panel whose one
  /// subject is a line drawn right above it in a different colour. **The same
  /// class as the six `ColorScheme` fallbacks tasks 11.200 and 11.201 found,
  /// and one no contrast check can catch, because green is perfectly
  /// legible.**
  ///
  /// **This reads both ends out of the widget tree** rather than comparing
  /// each to a theme token by name — a check keyed on a token's name passes
  /// whatever that name happens to resolve to (task 11.197). What it does not
  /// reach is the last step, from `ElevationProfilePanel.lineColor` to the
  /// pixels: the painter is private and its one use of this colour has no
  /// branch in it.
  group('the elevation profile matches the line it is about (task 11.207)',
      () {
    testWidgets('the navigation panel is drawn in the navigation line\'s own '
        'colour', (tester) async {
      useWideSurface(tester);
      final project = sampleProject();
      final container = await readyContainer(
        tester,
        project: project,
        overrides: [
          gpsPositionProvider.overrideWith(
            (ref) => Stream.value(
              Position(
                latitude: 35.02,
                longitude: -111.68,
                timestamp: DateTime.utc(2026, 9, 9, 12),
                accuracy: 5,
                altitude: 1500,
                altitudeAccuracy: 4,
                heading: 0,
                headingAccuracy: 5,
                speed: 0,
                speedAccuracy: 0,
              ),
            ),
          ),
        ],
      );
      await pumpScreen(tester, container);
      // Set after the first build: the notifier restores itself from
      // preferences on build, so a value written before the screen mounts is
      // overwritten by the restore.
      container.read(navigationTargetProvider.notifier).set(
            const NavigationTarget(
              label: 'Coco',
              latitude: 35.02,
              longitude: -111.62,
            ),
          );
      await tester.pump();

      final panel = tester.widget<ElevationProfilePanel>(
        find.byKey(const ValueKey('map-navigation-panel')),
      );
      final navLine = tester
          .widgetList<PolylineLayer>(find.byType(PolylineLayer))
          .expand((layer) => layer.polylines)
          .where((p) => p.strokeWidth == 3)
          .toList();

      expect(navLine, hasLength(1),
          reason: 'the navigation line is not on the map, so this test is '
              'comparing the panel against nothing');
      expect(
        panel.lineColor,
        navLine.single.color,
        reason: 'the profile is a picture of the ground under the navigation '
            'line and is drawn in a different colour from it',
      );
      expect(
        panel.lineColor,
        isNot(Theme.of(tester.element(find.byType(MapScreen))).colorScheme.primary),
        reason: 'back to the brand green, which is the colour this panel had '
            'when nobody had chosen one',
      );
    });
  });

  // **Task 11.318 item 5. Keep this group AFTER every test that gives the map a
  // GPS fix.** A fix makes the screen start a viewshed, and the calculation is
  // still running when the test that started it ends and its container is
  // disposed. Its result then writes to the progress bar's provider, which is
  // gone, and Riverpod raises "UnmountedRefException ... after the test had
  // completed" -- blamed on whichever test is running at that moment. While the
  // navigation-panel test above was the last in the file the late error landed
  // after the run and was never seen; any test placed after it failed, every
  // time. This test is that test, on purpose: it passes only if the late write
  // is harmless.
  group('a test that runs after a GPS one (task 11.318 item 5)', () {
    testWidgets('is not failed by the previous test\'s viewshed', (tester) async {
      useWideSurface(tester);
      final container = await readyContainer(tester, project: sampleProject());
      await pumpScreen(tester, container);
      expect(find.byType(MapScreen), findsOneWidget);
    });
  });

  // The isolated width-threshold measurement for this same defect lives in
  // its own file, `truth_point_row_overflow_width_test.dart` — kept out of
  // this one deliberately: run inside this file (after the many heavy real-
  // sqlite/real-network tests above it), it hit a 10-minute timeout, most
  // likely from leftover async state (e.g. the real tile-server HTTP
  // requests this file's own doc comment says "never resolve under `flutter
  // test`") bleeding into a later test in the same isolate. A plain
  // three-button `Row` has no such dependency, so it doesn't need to share
  // this file's isolate at all.
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart' show CompassEvent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/compass_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/providers/join_request_watcher.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/project_deletion_provider.dart';
import 'package:tritrack/core/providers/project_link_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/core/providers/sync_conflicts_provider.dart';
import 'package:tritrack/core/providers/sync_dropped_rows_provider.dart';
import 'package:tritrack/core/providers/sync_held_rows_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/sync/project_deletion_notice.dart';
import 'package:tritrack/data/sync/project_joiner.dart' show JoinableProject;
import 'package:tritrack/features/map/models/offline_region.dart';
import 'package:tritrack/features/compass/screens/compass_screen.dart';
import 'package:tritrack/features/identity/screens/identity_setup_screen.dart';
import 'package:tritrack/features/map/providers/download_manager.dart';
import 'package:tritrack/features/map/providers/offline_regions_provider.dart';
import 'package:tritrack/features/map/screens/map_screen.dart';
import 'package:tritrack/features/more/screens/animal_detail_screen.dart';
import 'package:tritrack/features/more/screens/animals_screen.dart';
import 'package:tritrack/features/more/screens/app_info_screen.dart';
import 'package:tritrack/features/more/screens/data_export_screen.dart';
import 'package:tritrack/features/more/screens/join_project_screen.dart';
import 'package:tritrack/features/more/screens/log_screen.dart';
import 'package:tritrack/features/more/screens/manage_offline_maps_screen.dart';
import 'package:tritrack/features/more/screens/more_screen.dart';
import 'package:tritrack/features/more/screens/observation_sharing_screen.dart';
import 'package:tritrack/features/more/screens/offline_data_map_screen.dart';
import 'package:tritrack/features/more/screens/pretrip_checklist_screen.dart';
import 'package:tritrack/features/more/screens/profile_screen.dart';
import 'package:tritrack/features/more/screens/project_setup_screen.dart';
import 'package:tritrack/features/more/screens/new_season_screen.dart';
import 'package:tritrack/features/more/screens/members_screen.dart';
import 'package:tritrack/features/more/screens/project_members_screen.dart';
import 'package:tritrack/features/more/screens/projects_screen.dart';
import 'package:tritrack/features/more/screens/server_config_screen.dart';
import 'package:tritrack/features/more/screens/sync_status_screen.dart';
import 'package:tritrack/features/more/screens/tag_database_screen.dart';
import 'package:tritrack/features/more/screens/tags_screen.dart';
import 'package:tritrack/compass/compass_controller.dart';
import 'package:tritrack/compass/compass_reading.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/features/observations/screens/bearing_map_capture_screen.dart';
import 'package:tritrack/features/observations/screens/observation_logging_screen.dart';
import 'package:tritrack/localization/declination/declination_override_provider.dart';
import 'package:tritrack/features/observations/screens/record_position_preview_screen.dart';
import 'package:tritrack/features/position_estimation/screens/position_estimation_screen.dart';
import 'package:tritrack/features/splash/splash_screen.dart';
import 'package:tritrack/routing/app_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';
import '../data/sync/fake_sync_transport.dart';
import '../support/app_shell_harness.dart';
import '../support/fake_path_provider.dart';
import '../support/fake_session_store.dart';
import '../support/fake_shared_preferences.dart';
import '../support/roboto_font.dart';
import '../support/text_scale_probe.dart';

/// **Task 11.233 — the clipped-text instrument only ever saw the screens
/// somebody remembered to pump.**
///
/// `clippedTexts` (`text_scale_probe.dart`) has never been wrong about what
/// it saw; it has been silent about everything nobody pointed it at, and on
/// 2026-09-12 that was five test files against 26 routable screens. This
/// sweep closes that gap: every screen the router actually serves, pumped at
/// every text size an iPhone offers, **in Roboto** rather than
/// `flutter_test`'s ~1.6x-wider fallback — the same mistake task 11.229 made
/// that task 11.232 had to unwind.
///
/// ## Discovered from the router, not from a list
///
/// [_discoverRoutePaths] walks the real [appRouter]'s route tree at runtism
/// runtime and returns every path template it finds
/// (`/more/animals/:individualId`, not a resolved URL). [_screenBuilders]
/// below is keyed on those same templates, and [_routeCoverageIsComplete]
/// below refuses to run if the two sets disagree — so a route the router
/// grows tomorrow fails this file loudly instead of silently staying
/// unmeasured the way the five-test-file list did.
///
/// ## What this does and does not do
///
/// It pumps one representative, populated state per screen — a project with
/// one collar, one animal, **three bearings and a saved three-bearing
/// estimate with an ellipse** (task 11.332; it was one bearing, which put no
/// estimate anywhere) — not the full state space each screen's own tests
/// already cover. **Ranking, not fixing**: per the task, nothing here is
/// repaired unless it clips at the *default* text size, which is live for
/// anybody today.
///
/// ## What fails: a silent cut, or a sentence cut short by "…" (task 11.332)
///
/// Until task 11.332 the sweep failed only on a cut with no sign
/// (`ClippedText.silent`), so the owner's deletion countdown on Projects,
/// which lost "or cancel from ⋮" to an ellipsis on the 6.1-inch phone (task
/// 11.323), would have passed even if it had been on screen. It fails now
/// on `ClippedText.fails`, and **the line between a deliberate one-line
/// truncation and a sentence cut short is read from the widget**, as
/// `ClippedText.cutsRunningText` says in full:
///
/// - **allowed** — `maxLines: 1` or `softWrap: false`; or, in a `Text`
///   allowed several lines, a cut whose hard line (text between two `\n`)
///   began on the last line shown, so it was given one line;
/// - **fails** — a hard line that wrapped and then lost its end; and an
///   ellipsis with **no** line limit, which cuts at the first line without
///   anybody having said one line (form fields' error and helper text do
///   that by default, which is how the server address field's refusal was
///   showing one line in three at the default size — fixed in `AppTheme`).
///
/// **Every place `lib/` truncates on purpose, as of 2026-10-10** — found by
/// searching `lib/` for `TextOverflow.`, `maxLines:` and `softWrap: false`
/// (re-run that search to recompute it; this list is the explanation, the
/// rule above is the control):
///
/// | Where | What is cut | Side of the line |
/// |---|---|---|
/// | `map_screen.dart` `_MarkerLabel` | the label under an estimate, truth point or shared bearing (kind · tag · frequency) | one line, allowed |
/// | `map_screen.dart` `_SharedObservationBanner` | "Previewing shared observation: TAG" | one line, allowed |
/// | `log_screen.dart` bearing row | "WHEN · WHO" | one line, allowed |
/// | `sync_status_screen.dart` conflict row | the row key | one line, allowed |
/// | `tag_database_screen.dart` | "FREQ MHz · TAG" on a library tag's floating card | one line, allowed |
/// | `offline_data_map_screen.dart` | a label in the map's key | one line, allowed |
/// | `observation_logging_screen.dart` (2) | the pulse-mode line, and the caption over each wheel (its `semanticsLabel` reads it whole) | one line, allowed |
/// | `position_estimation_screen.dart` (4) | the tag button's name, the *Distance* button, the header's caution count, "N of M selected" | one line, allowed |
/// | `wheel_picker.dart` | each tag on the Record wheel | one line, allowed |
/// | `segmented_toggle.dart` | each segment's label | one line, allowed |
/// | `tag_form.dart` | the dropdown's selected line (its `Semantics` reads it whole) | one line, allowed |
/// | `projects_screen.dart` | the banner line(s) and the description under a project; the description keeps one line | the description: allowed; a banner line cut: fails |
/// | `elevation_profile_panel.dart` header | "To TARGET · DISTANCE …", two lines, a measured cap (task 11.207) | fails if cut; whole in Roboto through xxxLarge (`elevation_profile_panel_test.dart`) |
/// | `elevation_profile_panel.dart` gaps line | "Part of this line has no elevation data…", two lines | fails if cut; whole in Roboto through xxxLarge (same file) |
/// | every form field (`AppTheme.inputDecorationTheme`) | error and helper text, up to `AppTheme.formMessageMaxLines` | fails if cut |
///
/// ## What the fixtures reach, and what they do not (task 11.332 item 2)
///
/// Reached since 11.332: the owner's deletion countdown and a Trash row on
/// Projects; the estimate's pin and ellipse on the Map; and, in
/// [_stateBuilders], the Position screen's cautions sheet, Past estimates,
/// the Map's estimate card (all three carry the few-bearings caution) and
/// the server address field's refusal.
///
/// **Not reached**, each a state behind data or a tap this sweep does not
/// make: a member's view of a scheduled deletion and the snapshot and
/// not-syncing-yet lines on Projects; Sync status with held, dropped or
/// conflicting rows (its providers return empty lists here); the Record
/// screen's held-overlap card and quick-add dialogs; every dialog (Move to
/// Trash, Delete permanently, the Tag ID clash, the truth-point and
/// declination dialogs' error lines); the Pre-Trip Checklist's failing rows;
/// the navigation panel; Join a project with projects listed or a request
/// pending; and any field's refusal but the server address. The elevation
/// panel's two capped lines are measured in their own test instead.
void main() {
  late List<ScreenClipRecord> results;

  setUpAll(() async {
    await loadRobotoFromSdkCache();
    results = [];
  });

  tearDownAll(() {
    _printReport(results);
  });

  test('every route the app serves has a pump function in this sweep', () {
    final discovered = _discoverRoutePaths();
    final covered = _screenBuilders.keys.toSet();
    final missing = discovered.difference(covered);
    final extra = covered.difference(discovered);
    expect(
      missing,
      isEmpty,
      reason: 'The router now serves a path this sweep never pumps: '
          '$missing. Add it to _screenBuilders in this file — a route '
          'missing from here is a screen this instrument is silent about, '
          'which is the exact gap this task exists to close.',
    );
    expect(
      extra,
      isEmpty,
      reason: 'This sweep pumps a path the router no longer serves: $extra. '
          'Remove it — a stale entry here is a hand-maintained list drifting '
          'the other direction.',
    );
  });

  // Task 11.332 item 2: the routes' first frames, then the states a route
  // only reaches after a tap (a sheet, a card) that show long text.
  for (final entry in [..._screenBuilders.entries, ..._stateBuilders.entries]) {
    testWidgets(
      'clipped-text ladder: ${entry.key}',
      timeout: const Timeout(Duration(minutes: 5)),
      (tester) async {
        installFakeSharedPreferences();
        installFakePathProvider();

        String? floorName;
        double? floorScale;
        List<ClippedText> floorClips = const [];

        for (final scale in iosTextScalesUpward) {
          final built = await entry.value(tester, scale);
          final overflows = built.overflows;
          // Task 11.332: a silent cut, or a sentence that lost its end to
          // an ellipsis (`ClippedText.cutsRunningText` says where the line
          // between that and a one-line label is drawn).
          final clips =
              clippedTexts(tester).where((c) => c.fails).toList();
          // A striped overflow at least announces itself; this sweep is
          // about the silent failure, so a stripe alone does not set the
          // floor, but it is worth knowing about.
          if (clips.isNotEmpty && floorScale == null) {
            floorScale = scale;
            floorName = textScaleName(scale);
            floorClips = clips;
          }
          if (overflows.isNotEmpty && floorScale == null) {
            // Record a stripe too, so the table does not silently prefer a
            // clip that happens to come first.
            floorScale ??= scale;
            floorName ??= '${textScaleName(scale)} (striped)';
          }
          await built.dispose();

          // Task 11.257 — the sweep had no reader; this is it. A clip or a
          // stripe at or below `dynamicTypeSliderCeiling` (xxxLarge, the
          // ordinary Dynamic Type slider's top stop — see
          // text_scale_probe.dart) is reachable by anybody, no hidden switch
          // required, so it fails the run. Above that bar the sweep still
          // records what it found (above, and in the printed report) but
          // does not fail, because reaching it needs *Larger Accessibility
          // Sizes*, a setting the app mentions nowhere — see
          // RELEASE_CHECKLIST.md section F.
          if (scale <= dynamicTypeSliderCeiling) {
            expect(
              clips,
              isEmpty,
              reason: '${entry.key} cuts text with no sign, or cuts a '
                  'sentence short with an ellipsis, at '
                  '${textScaleName(scale)}, at or below the ordinary '
                  'Dynamic Type slider\'s ceiling: '
                  '${clips.join('; ')}',
            );
            expect(
              overflows,
              isEmpty,
              reason: '${entry.key} overflows its layout at '
                  '${textScaleName(scale)}, at or below the ordinary '
                  'Dynamic Type slider\'s ceiling: ${overflows.join('; ')}',
            );
          }
        }

        results.add(
          ScreenClipRecord(
            path: entry.key,
            floorScaleName: floorName,
            clips: floorClips,
          ),
        );
      },
    );
  }
}

/// One screen's pump, run at [scale], returning what to inspect and how to
/// tear it down before the next scale in the ladder.
typedef _ScreenPump = Future<_PumpedScreen> Function(
  WidgetTester tester,
  double scale,
);

class _PumpedScreen {
  _PumpedScreen({required this.overflows, required this.dispose});
  final List<String> overflows;
  final Future<void> Function() dispose;
}

class ScreenClipRecord {
  ScreenClipRecord({
    required this.path,
    required this.floorScaleName,
    required this.clips,
  });

  final String path;

  /// The smallest text scale at which this screen showed a silent clip (or
  /// a stripe), null if it stayed clean through AX5.
  final String? floorScaleName;
  final List<ClippedText> clips;
}

void _printReport(List<ScreenClipRecord> results) {
  final sorted = [...results]..sort((a, b) {
      if (a.floorScaleName == null && b.floorScaleName == null) {
        return a.path.compareTo(b.path);
      }
      if (a.floorScaleName == null) return 1;
      if (b.floorScaleName == null) return -1;
      return a.path.compareTo(b.path);
    });
  // ignore: avoid_print
  print('\n=== Task 11.233 — clipped-text sweep, in Roboto ===');
  for (final r in sorted) {
    if (r.floorScaleName == null) {
      // ignore: avoid_print
      print('CLEAN through AX5   ${r.path}');
    } else {
      final what = r.clips.isEmpty
          ? '(stripe, not a silent clip)'
          : r.clips.map((c) => c.toString()).join('; ');
      // ignore: avoid_print
      print('CLIPS AT ${r.floorScaleName.toString().padRight(18)} '
          '${r.path}  —  $what');
    }
  }
  // ignore: avoid_print
  print('=== end sweep ===\n');
}

// ---------------------------------------------------------------------------
// Route discovery — walks the real router, never a hand list.
// ---------------------------------------------------------------------------

Set<String> _discoverRoutePaths() {
  final container = ProviderContainer();
  final router = container.read(appRouterProvider);
  final paths = <String>{};
  void visit(List<RouteBase> routes, String parent) {
    for (final route in routes) {
      if (route is GoRoute) {
        final full = route.path.startsWith('/')
            ? route.path
            : (parent == '/' ? '/${route.path}' : '$parent/${route.path}');
        paths.add(full);
        visit(route.routes, full);
      } else {
        visit(route.routes, parent);
      }
    }
  }

  visit(router.configuration.routes, '/');
  container.dispose();
  return paths;
}

// ---------------------------------------------------------------------------
// Shared fixture: one project, one collar, one animal, one bearing.
// ---------------------------------------------------------------------------

const _projectId = 'project-1';
const _ownerId = 'user-owner';
const _tagId = 'tag-1';
const _individualId = 'individual-1';
const _estimateId = 'est-1';

/// Where the seeded animal is: the saved estimate's point.
const _animalLat = 35.195;
const _animalLon = -111.615;

/// Three stations about a kilometre from the animal, spread over a half
/// circle, each with a bearing a degree or two off the true one — ordinary
/// geometry, so the live estimate has an ellipse and no caution but the
/// few-bearings one.
final List<({double lat, double lon, double bearing})> _stations = [
  for (final (i, errorDeg) in const [1.5, -2.0, 0.5].indexed)
    () {
      final around = math.pi * i / 2 - math.pi / 2;
      final distanceM = 1000.0 + 300.0 * i;
      final lat = _animalLat - distanceM * math.cos(around) / 110574;
      final lon = _animalLon -
          distanceM *
              math.sin(around) /
              (111320 * math.cos(_animalLat * math.pi / 180));
      final dx =
          (_animalLon - lon) * math.cos(_animalLat * math.pi / 180) * 111320;
      final dy = (_animalLat - lat) * 110574;
      final bearing = (math.atan2(dx, dy) * 180 / math.pi + errorDeg + 360) % 360;
      return (lat: lat, lon: lon, bearing: bearing);
    }(),
];

Future<ProviderContainer> _seedProjectContainer(
  WidgetTester tester, {
  List<dynamic> extraOverrides = const [],
}) async {
  final project = sampleProject(id: _projectId, ownerUserId: _ownerId);
  final owner = sampleUser(id: _ownerId, email: 'owner@example.com');
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
      currentUserProvider.overrideWith((ref) async => owner),
      currentProjectProvider.overrideWith((ref) async => project),
      gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
      compassHeadingProvider
          .overrideWith((ref) => const Stream<CompassEvent>.empty()),
      accelerometerReadingProvider.overrideWith((ref) => const Stream.empty()),
      magnetometerReadingProvider.overrideWith((ref) => const Stream.empty()),
      ...extraOverrides,
    ],
  );

  await tester.runAsync(() async {
    final database = await container.read(appDatabaseProvider.future);
    final db = database.raw;
    await db.insert(Tables.users, owner.toColumns());
    await db.insert(Tables.projects, project.toColumns());
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'membership-owner',
        projectId: _projectId,
        userId: _ownerId,
        role: ProjectRole.owner,
      ).toColumns(),
    );
    await db.insert(
      Tables.tags,
      sampleTag(id: _tagId, projectId: _projectId).toColumns(),
    );
    await db.insert(
      Tables.individuals,
      sampleIndividual(id: _individualId, projectId: _projectId).toColumns(),
    );
    await db.insert(
      Tables.deployments,
      sampleDeployment(
        id: 'deployment-1',
        projectId: _projectId,
        tagId: _tagId,
        individualId: _individualId,
      ).toColumns(),
    );
    // Task 11.332 item 6: three bearings and a saved three-bearing estimate
    // with an ellipse, so every line that needs an ellipse (the few-bearings
    // caution above all) can be on screen. One bearing, as before, could not
    // put an estimate anywhere.
    for (final (i, station) in _stations.indexed) {
      await db.insert(
        Tables.observations,
        sampleObservation(
          id: 'obs-${i + 1}',
          projectId: _projectId,
          userId: _ownerId,
          tagId: _tagId,
          sessionId: null,
          tagVersionId: null,
          latitude: station.lat,
          longitude: station.lon,
        )
            .copyWith(
              trueNorthBearing: station.bearing,
              magneticBearing: station.bearing,
            )
            .toColumns(),
      );
    }
    await db.insert(
      Tables.estimatedPositions,
      sampleEstimatedPosition(
        id: _estimateId,
        projectId: _projectId,
        tagId: _tagId,
      ).copyWith(latitude: _animalLat, longitude: _animalLon).toColumns(),
    );
    await container.read(activeUserIdProvider.notifier).set(_ownerId);
    await container.read(activeProjectIdProvider.notifier).set(_projectId);
  });

  return container;
}

/// The shared seed, plus what the Projects screen needs to show its longest
/// rows: a server this phone is signed in to, the open project scheduled for
/// deletion with its owner looking (the countdown), and a project in the
/// Trash. The same seeding `projects_screen_phone_layout_test.dart` uses.
Future<ProviderContainer> _seedProjectsWithDeletion(WidgetTester tester) async {
  final project = sampleProject(id: _projectId, ownerUserId: _ownerId);
  final server = FakeSyncTransport()
    ..sessionUserId = _ownerId
    ..sessionEmail = 'owner@example.com'
    ..serverProjects.add(
      ProjectSummary(
        projectId: _projectId,
        projectName: project.projectName,
        ownerUserId: _ownerId,
        role: ownerMembershipRole,
      ),
    )
    ..serverDeletedProjects.add(
      DeletedProjectSummary(
        projectId: 'project-in-trash',
        projectName: 'Pronghorn calving survey 2025',
        deletedAt: DateTime.utc(2026, 9, 20, 9, 30),
      ),
    );
  final container = await _seedProjectContainer(
    tester,
    extraOverrides: [
      allProjectsProvider.overrideWith((ref) async => [project]),
      serverTransportProvider.overrideWith((ref) async => server),
      sessionStoreProvider.overrideWithValue(
        FakeSessionStore(
          StoredSession(
            token: 'not-a-real-token',
            userId: _ownerId,
            email: 'owner@example.com',
            expiresAt: DateTime.now().add(const Duration(days: 30)),
          ),
        ),
      ),
    ],
  );
  await tester.runAsync(() async {
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://tritrack.example.org');
    final store = container.read(syncStateStoreProvider);
    await store.markProjectLinked(_projectId);
    await store.setDeletionNotice(
      _projectId,
      ProjectDeletionNotice(
        destroyAt: DateTime.now().toUtc().add(const Duration(days: 27, hours: 3)),
        learnedAt: DateTime.now().toUtc(),
      ),
    );
    await container.read(deviceIdProvider.future);
    await container.read(syncControllerProvider.future);
    container
      ..listen(ownedProjectIdsProvider, (_, _) {})
      ..listen(departedProjectIdsProvider, (_, _) {})
      ..listen(snapshotProjectIdsProvider, (_, _) {})
      ..listen(unsyncedMemberProjectIdsProvider, (_, _) {})
      ..listen(projectDeletionNoticesProvider, (_, _) {})
      ..listen(undeliveredProjectDeletionsProvider, (_, _) {})
      ..listen(currentSessionProvider, (_, _) {})
      ..listen(deletedOnServerListingProvider, (_, _) {});
    await container.read(ownedProjectIdsProvider.future);
    await container.read(departedProjectIdsProvider.future);
    await container.read(snapshotProjectIdsProvider.future);
    await container.read(unsyncedMemberProjectIdsProvider.future);
    await container.read(projectDeletionNoticesProvider.future);
    await container.read(undeliveredProjectDeletionsProvider.future);
    // The Trash listing gates on the session, so the session resolves first.
    await container.read(currentSessionProvider.future);
    await container.read(deletedOnServerListingProvider.future);
  });
  return container;
}

/// Pumps until [finder] finds something, on the real clock (the screens
/// behind these sheets read SQLite, and the maps keep asking for tiles, so
/// `pumpAndSettle` never settles). Fails, naming [what], if it never does —
/// a state the sweep cannot reach must not pass as one it measured clean.
Future<void> _pumpUntilShown(
  WidgetTester tester,
  Finder finder,
  String what,
) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw TestFailure(
          'clipped-text sweep: $what never appeared, so nothing in that '
          'state was measured.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  });
}

/// The few-bearings caution, which needs an estimate with an ellipse from
/// five or fewer bearings — what [_seedProjectContainer] now plants.
final _fewBearings = find.textContaining('Few bearings');

// ---------------------------------------------------------------------------
// States past a route's first frame — task 11.332 item 2.
// ---------------------------------------------------------------------------

/// **States a route reaches only after a tap**, each with long text the
/// route's first frame does not show. Not discovered from anything: the
/// router lists routes, not sheets, so this list is a judgement about which
/// states carry sentences. The ones not here are named in the comment on
/// [_screenBuilders].
final Map<String, _ScreenPump> _stateBuilders = {
  // The cautions sheet, opened from the Position screen's "N caution"
  // button: the few-bearings line is the longest caution there is.
  '/position · cautions sheet': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    final pumped = await _inShell(
      tester,
      scale,
      container: container,
      screen: const PositionEstimationScreen(),
      tabIndex: 3,
    );
    final button = find.textContaining('caution');
    await _pumpUntilShown(tester, button, 'the Position screen\'s cautions button');
    await tester.tap(button.first);
    await _pumpUntilShown(tester, _fewBearings, 'the few-bearings caution');
    return pumped;
  },
  // Past estimates, with the saved three-bearing estimate and its caution.
  '/position · Past estimates': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    final pumped = await _inShell(
      tester,
      scale,
      container: container,
      screen: const PositionEstimationScreen(),
      tabIndex: 3,
    );
    final open = find.byTooltip('Past estimates for this tag');
    await _pumpUntilShown(tester, open, 'the Past estimates button');
    await tester.tap(open);
    await _pumpUntilShown(tester, _fewBearings, 'the saved estimate\'s caution');
    return pumped;
  },
  // A form field's refusal. Error text is drawn with an ellipsis and, unless
  // `errorMaxLines` says otherwise, one line: this field's refusals are
  // sentences (an address typed without https:// is the commonest).
  '/more/server · address refused': (tester, scale) async {
    final container = ProviderContainer(
      overrides: [sessionStoreProvider.overrideWithValue(FakeSessionStore())],
    );
    final pumped = await _inShell(
      tester,
      scale,
      container: container,
      screen: const ServerConfigScreen(),
      tabIndex: 4,
    );
    await tester.enterText(find.byType(TextFormField).first, '192.168.1.42:8080');
    await _pumpUntilShown(
      tester,
      find.textContaining('Put https:// in front of it'),
      "the server field's refusal",
    );
    return pumped;
  },
  // The Map's card for the saved estimate, opened by tapping its pin.
  '/map · estimate card': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    final pumped = await _inShell(
      tester,
      scale,
      container: container,
      screen: const MapScreen(),
      tabIndex: 0,
    );
    final pin = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_EstimateMarker',
    );
    await _pumpUntilShown(tester, pin, 'the estimate\'s pin on the Map');
    final box = tester.getRect(pin.first);
    // The ring is the top 18 px of the pin; its center is the hit point.
    await tester.runAsync(() async {
      await tester.tapAt(Offset(box.center.dx, box.top + 9));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    await _pumpUntilShown(tester, _fewBearings, 'the estimate card\'s caution');
    return pumped;
  },
};

// ---------------------------------------------------------------------------
// Per-screen pumps.
// ---------------------------------------------------------------------------

/// Wraps [pumpInAppShell]'s builder shape so each entry below is one line:
/// seed (or not), build the widget, hand back the shell pump.
Future<_PumpedScreen> _inShell(
  WidgetTester tester,
  double scale, {
  required ProviderContainer container,
  required Widget screen,
  required int tabIndex,
}) async {
  final overflows = collectLayoutOverflows();
  await pumpInAppShell(
    tester,
    container: container,
    screen: screen,
    tabIndex: tabIndex,
    textScale: scale,
  );
  return _PumpedScreen(
    overflows: overflows,
    dispose: () async => container.dispose(),
  );
}

/// The same idea, for the three screens the router pushes **outside** the
/// tab shell (no bottom `NavigationBar` in the real app either).
Future<_PumpedScreen> _standalone(
  WidgetTester tester,
  double scale, {
  required ProviderContainer container,
  required Widget screen,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final overflows = collectLayoutOverflows();
  usePhoneGeometry(tester);
  final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => screen)]);
  await tester.runAsync(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();
    final deadline = DateTime.now().add(timeout);
    while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw TestFailure(
          '_standalone: $screen was still showing a spinner after '
          '${timeout.inSeconds}s.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  });
  return _PumpedScreen(
    overflows: overflows,
    dispose: () async {
      router.dispose();
      container.dispose();
    },
  );
}

final Map<String, _ScreenPump> _screenBuilders = {
  '/splash': (tester, scale) async {
    final container = ProviderContainer(
      overrides: [
        splashDurationProvider.overrideWithValue(Duration.zero),
        // Never resolves, so the branded splash frame is what stays on
        // screen to measure — the same trick splash_failure_test.dart uses.
        currentUserProvider.overrideWith((ref) => Completer<User>().future),
      ],
    );
    final overflows = collectLayoutOverflows();
    usePhoneGeometry(tester);
    final router =
        GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const SplashScreen())]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();
    // The zero-duration `Future.delayed` inside `_resolveAndNavigate`
    // schedules a real `Timer(Duration.zero)` — one `pump()` flushes
    // microtasks but not a due timer, so a second one is needed to fire it
    // before the test ends, or flutter_test's own invariant check ("a timer
    // is still pending") fails a test that never touched a timer of its own.
    await tester.pump(Duration.zero);
    return _PumpedScreen(
      overflows: overflows,
      dispose: () async {
        router.dispose();
        container.dispose();
      },
    );
  },
  '/identity-setup': (tester, scale) => _standalone(
        tester,
        scale,
        container: ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          ],
        ),
        screen: const IdentitySetupScreen(),
      ),
  '/record-preview': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _standalone(
      tester,
      scale,
      container: container,
      screen: const RecordPositionPreviewScreen(),
    );
  },
  // Task 11.315: with a heading and a pin, so the map, the key card and the
  // hold button are what is measured rather than the no-position sentence.
  '/record-bearing-map': (tester, scale) async {
    final container = await _seedProjectContainer(
      tester,
      extraOverrides: [compassControllerProvider.overrideWith(_SweepCompass.new)],
    );
    await tester.runAsync(() async {
      container.listen(observationFormProvider, (_, _) {});
      await container.read(observationFormProvider.future);
      container.read(observationFormProvider.notifier)
        ..setTag(_tagId)
        ..setManualPosition(true, lat: 35.19, lon: -111.62);
      // The World Magnetic Model loads from an asset this harness cannot
      // reach; an override is the declination the screen uses first anyway.
      await container.read(declinationOverrideProvider.future);
      await container.read(declinationOverrideProvider.notifier).set(10);
    });
    return _standalone(
      tester,
      scale,
      container: container,
      screen: const BearingMapCaptureScreen(),
    );
  },
  '/map': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(tester, scale, container: container, screen: const MapScreen(), tabIndex: 0);
  },
  '/record': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const ObservationLoggingScreen(),
      tabIndex: 1,
    );
  },
  '/compass': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const CompassScreen(),
      tabIndex: 2,
    );
  },
  '/position': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const PositionEstimationScreen(),
      tabIndex: 3,
    );
  },
  '/more': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(tester, scale, container: container, screen: const MoreScreen(), tabIndex: 4);
  },
  '/more/profile': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const ProfileScreen(),
      tabIndex: 4,
    );
  },
  // Task 11.332 item 2: with the owner's deletion countdown on the open
  // project and one project in the Trash. Before, this fixture scheduled no
  // deletion, so the countdown that lost "or cancel from ⋮" on the 6.1-inch
  // phone (task 11.323) was never on screen here.
  '/more/projects': (tester, scale) async {
    final container = await _seedProjectsWithDeletion(tester);
    final pumped = await _inShell(
      tester,
      scale,
      container: container,
      screen: const ProjectsScreen(),
      tabIndex: 4,
    );
    // A fixture that silently missed its state would measure the old one and
    // pass: these two say the rows are really there.
    await _pumpUntilShown(
      tester,
      find.textContaining('Deletion from the server scheduled'),
      "the owner's deletion countdown",
    );
    await _pumpUntilShown(
      tester,
      find.text('Pronghorn calving survey 2025', skipOffstage: false),
      'the Trash row',
    );
    return pumped;
  },
  '/more/projects/join': (tester, scale) async {
    // No server is configured for this sweep — this screen is only ever
    // reached from one that is (`ProjectsScreen`'s own gate), so this fakes
    // the two controllers that would otherwise reach a real transport and
    // throw `not_configured`, the same way its own future test should.
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        projectLinkControllerProvider.overrideWith(_EmptyProjectLinkController.new),
        joinRequestWatcherProvider.overrideWith(_EmptyJoinRequestWatcher.new),
      ],
    );
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const JoinProjectScreen(),
      tabIndex: 4,
    );
  },
  '/more/projects/:projectId/members': (tester, scale) async {
    final container = await _seedProjectContainer(
      tester,
      extraOverrides: [
        projectJoinSettingsProvider(_projectId).overrideWith(
          (ref) async => const JoinSettings(
            projectId: _projectId,
            joiningEnabled: true,
            teamSizeLimit: 50,
            memberCount: 1,
            pendingCount: 0,
          ),
        ),
        projectJoinRequestsProvider(_projectId)
            .overrideWith((ref) async => const []),
      ],
    );
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const ProjectMembersScreen(projectId: _projectId),
      tabIndex: 4,
    );
  },
  // Task 11.313: the More menu's own door to the same screen, for the open
  // project — seeded identically, reached without a projectId in the route.
  '/more/members': (tester, scale) async {
    final container = await _seedProjectContainer(
      tester,
      extraOverrides: [
        projectJoinSettingsProvider(_projectId).overrideWith(
          (ref) async => const JoinSettings(
            projectId: _projectId,
            joiningEnabled: true,
            teamSizeLimit: 50,
            memberCount: 1,
            pendingCount: 0,
          ),
        ),
        projectJoinRequestsProvider(_projectId)
            .overrideWith((ref) async => const []),
      ],
    );
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const MembersScreen(),
      tabIndex: 4,
    );
  },
  '/more/projects/:projectId/new-season': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    // The plan is a database read; resolved on the real clock before the
    // pump, the way every seeded screen here resolves its providers.
    await tester.runAsync(() async {
      container.listen(newSeasonPlanProvider(_projectId), (_, _) {});
      await container.read(newSeasonPlanProvider(_projectId).future);
    });
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const NewSeasonScreen(projectId: _projectId),
      tabIndex: 4,
    );
  },
  '/more/project-setup': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const ProjectSetupScreen(),
      tabIndex: 4,
    );
  },
  '/more/project-setup/new': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const ProjectSetupScreen(projectId: 'new'),
      tabIndex: 4,
    );
  },
  '/more/project-setup/:projectId': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const ProjectSetupScreen(projectId: _projectId),
      tabIndex: 4,
    );
  },
  '/more/animals': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const AnimalsScreen(),
      tabIndex: 4,
    );
  },
  '/more/animals/:individualId': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const AnimalDetailScreen(individualId: _individualId),
      tabIndex: 4,
    );
  },
  '/more/tags': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const TagsScreen(),
      tabIndex: 4,
    );
  },
  '/more/checklist': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const PreTripChecklistScreen(),
      tabIndex: 4,
    );
  },
  '/more/offline-maps': (tester, scale) async {
    final container = ProviderContainer(
      overrides: [gpsPositionProvider.overrideWith((ref) => const Stream.empty())],
    );
    await tester.runAsync(() async {
      await container.read(offlineRegionsProvider.future);
    });
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const ManageOfflineMapsScreen(),
      tabIndex: 4,
    );
  },
  '/more/offline-data-map': (tester, scale) async {
    final container = ProviderContainer(
      overrides: [
        offlineRegionsProvider.overrideWith(_EmptyOfflineRegions.new),
        downloadManagerProvider.overrideWith(() => _EmptyDownloadManager()),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    await tester.runAsync(() async {
      await container.read(offlineRegionsProvider.future);
    });
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const OfflineDataMapScreen(),
      tabIndex: 4,
    );
  },
  '/more/log': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const LogScreen(),
      tabIndex: 4,
    );
  },
  '/more/tag-database': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const TagDatabaseScreen(),
      tabIndex: 4,
    );
  },
  '/more/observation-sharing': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const ObservationSharingScreen(),
      tabIndex: 4,
    );
  },
  '/more/data-export': (tester, scale) async {
    final container = await _seedProjectContainer(tester);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const DataExportScreen(),
      tabIndex: 4,
    );
  },
  '/more/server': (tester, scale) async {
    final container = ProviderContainer(
      overrides: [sessionStoreProvider.overrideWithValue(FakeSessionStore())],
    );
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const ServerConfigScreen(),
      tabIndex: 4,
    );
  },
  '/more/app-info': (tester, scale) async {
    PackageInfo.setMockInitialValues(
      appName: 'TriTrack',
      packageName: 'edu.nau.tritrack',
      version: '1.4.2',
      buildNumber: '87',
      buildSignature: '',
    );
    final container = ProviderContainer();
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const AppInfoScreen(),
      tabIndex: 4,
    );
  },
  '/more/sync-status': (tester, scale) async {
    final container = ProviderContainer(
      overrides: [
        syncControllerProvider.overrideWith(LiveSyncStatusController.new),
        syncHeldRowDetailsProvider(_projectId).overrideWith((ref) async => const []),
        syncDroppedRowsProvider(_projectId).overrideWith((ref) async => const []),
        syncConflictsProvider(_projectId).overrideWith((ref) async => const []),
      ],
    );
    await container.read(activeProjectIdProvider.notifier).set(_projectId);
    return _inShell(
      tester,
      scale,
      container: container,
      screen: const SyncStatusScreen(),
      tabIndex: 4,
    );
  },
};

class _EmptyOfflineRegions extends OfflineRegions {
  @override
  Future<List<OfflineRegion>> build() async => const [];
}

class _EmptyDownloadManager extends DownloadManager {
  @override
  List<DownloadJob> build() => const [];
}

class _EmptyProjectLinkController extends ProjectLinkController {
  @override
  void build() {}

  @override
  Future<List<JoinableProject>> listAvailableToJoin() async => const [];
}

class _EmptyJoinRequestWatcher extends JoinRequestWatcher {
  @override
  JoinWatch build() => const JoinWatch();

  @override
  Future<void> refresh() async {}
}

/// A compass pointing somewhere, for the one screen whose layout changes
/// once there is a heading (task 11.315's *Take on map*).
class _SweepCompass extends CompassController {
  @override
  CompassReading build() =>
      CompassReading.initial.copyWith(magneticHeadingDeg: 100);
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../compass/compass_controller.dart';
import '../../../compass/compass_reading.dart';
import '../../../routing/tab_visibility.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../viewshed/dem_tile_store.dart';
import '../../../core/providers/gps_provider.dart';
import '../../../core/providers/project_link_provider.dart';
import '../../../core/providers/server_config_provider.dart';
import '../../../data/models/project.dart';
import '../../map/providers/download_manager.dart';
import '../../map/providers/offline_regions_provider.dart';
import '../widgets/finish_setting_up_sheet.dart';
import '../../../core/theme/design_tokens.dart';
import '../../map/services/tile_cache.dart';
import '../../../widgets/load_failure.dart';

/// Pre-Trip Checklist: "surfaced before leaving connectivity... the classic
/// field disaster is arriving on site with no offline data and no signal to
/// fetch it" (design doc). This is the least-specified of the five Phase 4
/// screens — no wireframe or hi-fi mockup exists for it — so the layout here
/// (a simple list with live status indicators) is an original, minimal
/// design rather than a mockup match.
///
/// Map tiles and DEM now check the real Phase 5 offline caches (split into
/// two items, since one can be ready without the other) rather than the
/// Phase 4 bbox-defined proxy.
class PreTripChecklistScreen extends ConsumerWidget {
  const PreTripChecklistScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(currentProjectProvider);
    final gpsAsync = ref.watch(gpsPositionProvider);
    // Task 11.161: this screen lives inside the More branch, so it holds the
    // compass for as long as it stays on that branch's navigator stack. Its
    // calibration row reads "not calibrated yet" while hidden, which nobody
    // sees; resuming costs one sensor sample.
    final compass = ref.watchWhileTabVisible(context, compassControllerProvider,
        whileHidden: CompassReading.initial);
    final userAsync = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Pre-Trip Checklist')),
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: DesignTokens.spacingScreenHorizontal,
          vertical: 16,
        ),
        children: [
          userAsync.when(
            loading: () => const _ChecklistItem(
              title: 'Identity configured',
              subtitle: 'Checking…',
              ok: false,
            ),
            error: (_, _) => const _ChecklistItem(
              title: 'Identity configured',
              subtitle: 'Could not check',
              ok: false,
            ),
            data: (user) => _ChecklistItem(
              title: 'Identity configured',
              subtitle: user.hasPlaceholderIdentity
                  ? 'Not set — open Profile under More to enter your name and email'
                  : '${user.firstName} ${user.lastName} · ${user.email}',
              ok: !user.hasPlaceholderIdentity,
            ),
          ),
          projectAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => LoadFailure(
              'this project',
              error: e,
              centered: false,
            ),
            data: (project) {
              if (project == null) {
                return const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Center(child: Text('Set up a project first.')),
                );
              }
              final tagsAsync = ref.watch(
                projectActiveTagsProvider(project.projectId),
              );

              return Column(
                children: [
                  _AreaMapsItem(project: project),
                  _PublishedItem(project: project),
                  FutureBuilder<int>(
                    future: TileCache.tileCount(),
                    builder: (context, snapshot) {
                      final count = snapshot.data;
                      return _ChecklistItem(
                        title: 'Map tiles downloaded',
                        subtitle: count == null
                            ? 'Checking…'
                            : (count > 0
                                  ? '$count tiles cached'
                                  : 'No tiles cached yet'),
                        ok: (count ?? 0) > 0,
                      );
                    },
                  ),
                  FutureBuilder<int>(
                    future: DemTileStore().tileCount(),
                    builder: (context, snapshot) {
                      final count = snapshot.data;
                      return _ChecklistItem(
                        title: 'Elevation data (DEM) downloaded',
                        subtitle: count == null
                            ? 'Checking…'
                            : (count > 0
                                  ? '$count elevation tile(s) cached'
                                  : 'No elevation data downloaded yet'),
                        ok: (count ?? 0) > 0,
                      );
                    },
                  ),
                  tagsAsync.when(
                    loading: () => const _ChecklistItem(
                      title: 'Tags loaded',
                      subtitle: 'Checking…',
                      ok: false,
                    ),
                    error: (_, _) => const _ChecklistItem(
                      title: 'Tags loaded',
                      subtitle: 'Could not check',
                      ok: false,
                    ),
                    data: (tags) => _ChecklistItem(
                      title: 'Tags loaded',
                      subtitle: tags.isEmpty
                          ? 'No active tags in this project'
                          : '${tags.length} active tag(s)',
                      ok: tags.isNotEmpty,
                    ),
                  ),
                  gpsAsync.when(
                    loading: () => const _ChecklistItem(
                      title: 'GPS acquiring',
                      subtitle: 'Waiting for a fix…',
                      ok: false,
                    ),
                    error: (_, _) => const _ChecklistItem(
                      title: 'GPS acquiring',
                      subtitle: 'GPS unavailable',
                      ok: false,
                    ),
                    data: (p) => _ChecklistItem(
                      title: 'GPS acquiring',
                      subtitle: 'Fix acquired · ±${p.accuracy.round()}m',
                      ok: true,
                    ),
                  ),
                  _ChecklistItem(
                    title: 'Compass calibrated',
                    subtitle: compass.isHeadingReliable
                        ? 'Heading reliable'
                        : (compass.magneticHeadingDeg == null
                              ? 'No compass reading yet'
                              : 'Interference detected — recalibrate'),
                    ok: compass.isHeadingReliable,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// **This project's area, downloaded for offline use** (task 11.324, item 1).
/// Where "Finish setting up"'s *Later* leaves the maps: done only when map
/// tiles and elevation each cover the whole area, with the same download one
/// tap away. The two rows below it still count everything on the device.
class _AreaMapsItem extends ConsumerWidget {
  const _AreaMapsItem({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const title = "Offline maps for this project's area";
    final area = ProjectAreaDownload.of(project);
    if (area == null) {
      return const _ChecklistItem(
        title: title,
        subtitle:
            'This project has no area yet. Set one in Projects → ⋮ → Edit '
            'project, then download it here.',
        ok: false,
      );
    }
    final jobs = ref.watch(downloadManagerProvider);
    final regions = ref.watch(offlineRegionsProvider).value;
    if (regions != null && area.isDownloaded(regions)) {
      return const _ChecklistItem(
        title: title,
        subtitle: 'Map and elevation for the whole area are on this device.',
        ok: true,
      );
    }
    if (area.isDownloading(jobs)) {
      return const _ChecklistItem(
        title: title,
        subtitle: 'Downloading. Keep TriTrack open until it finishes.',
        ok: false,
      );
    }
    return _ChecklistItem(
      title: title,
      subtitle: regions == null
          ? 'Checking…'
          : 'Not downloaded yet (${area.sizeLabel}).',
      ok: false,
      action: regions == null
          ? null
          : TextButton(
              onPressed: () async {
                final downloads = ref.read(downloadManagerProvider.notifier);
                final choice = await showFinishSettingUpSheet(
                  context,
                  publishAs: null,
                  maps: area,
                );
                if (choice.downloadMaps) area.start(downloads);
              },
              child: const Text('Download'),
            ),
    );
  }
}

/// **Published to the server** (task 11.324, item 1) — the other thing
/// "Finish setting up"'s *Later* leaves here. Absent on a device with no
/// server: working fully offline is a whole way to use the app (task 10.2),
/// and a row that can never turn green there would only nag.
class _PublishedItem extends ConsumerWidget {
  const _PublishedItem({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasServer =
        ref.watch(serverConfigProvider).value?.isConfigured ?? false;
    if (!hasServer) return const SizedBox.shrink();
    const title = 'Published to the server';
    return ref
        .watch(isProjectLinkedProvider(project.projectId))
        .when(
          loading: () => const _ChecklistItem(
            title: title,
            subtitle: 'Checking…',
            ok: false,
          ),
          error: (_, _) => const _ChecklistItem(
            title: title,
            subtitle: 'Could not check',
            ok: false,
          ),
          data: (linked) => _ChecklistItem(
            title: title,
            subtitle: linked
                ? 'On the server — your team can join it and sync.'
                : 'Not yet. An owner publishes it from Projects → ⋮ → '
                      'Publish to server.',
            ok: linked,
          ),
        );
  }
}

class _ChecklistItem extends StatelessWidget {
  const _ChecklistItem({
    required this.title,
    required this.subtitle,
    required this.ok,
    this.action,
  });

  final String title;
  final String subtitle;
  final bool ok;

  /// A way to do it from here, when there is one.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(
          ok ? Icons.check_circle : Icons.error_outline,
          color: ok ? colors.primary : colors.error,
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: action,
      ),
    );
  }
}

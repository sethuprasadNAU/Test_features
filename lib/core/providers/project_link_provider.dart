import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/repositories/repository_providers.dart';
import '../../data/sync/project_joiner.dart';
import '../../data/sync/project_publisher.dart';
import '../../data/sync/sync_engine.dart';
import '../../data/sync/sync_transport.dart';
import 'app_context_provider.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'device_id_provider.dart';
import 'server_config_provider.dart';
import 'server_transport_provider.dart';
import 'sync_provider.dart';

part 'project_link_provider.g.dart';

/// Whether [projectId] has been published or joined — the gate that decides
/// whether a "Publish" action or a sync attempt makes sense for it. A family
/// provider (not a single value) because a device typically holds several
/// local projects with different link states at once.
@riverpod
Future<bool> isProjectLinked(Ref ref, String projectId) =>
    ref.watch(syncStateStoreProvider).isProjectLinked(projectId);

/// The projects on this device the signed-in person **currently holds a
/// role on** that are **not yet linked to any server** — task 11.238's "why
/// has nothing left my phone" line, for `ImportCase.adopt`'s live-but-
/// unlinked project and for an ordinary local project nobody has published
/// yet (see [notSyncingYetOwnerDescription]'s doc for why those two cannot
/// be told apart, and why that is fine).
///
/// **Derived on every read, never stored — the same shape
/// [snapshotProjectIdsProvider] uses, on purpose** (11.238's brief: reuse the
/// mechanism 11.237 built rather than invent a second one). A project leaves
/// this set the moment it links, whether by Publish or by properly joining;
/// nothing here needs to know which import produced it, because `ImportCase`
/// is a report about one merge transaction and was never meant to survive
/// past it.
///
/// Same `ref`-after-`await` shape as [snapshotProjectIdsProvider], safe for
/// the same checked reason — see the note there (task 11.256).
@riverpod
Future<Set<String>> unsyncedMemberProjectIds(Ref ref) async {
  final projects = await ref.watch(allProjectsProvider.future);
  final userId = (await ref.watch(currentUserProvider.future)).userId;
  final membershipRepo = await ref.watch(
    projectMembershipRepositoryProvider.future,
  );
  final unsynced = <String>{};
  for (final project in projects) {
    final standing = await membershipRepo.projectStandingFor(
      project.projectId,
      userId,
    );
    // Excludes a snapshot holder and a departed member (both resolve to
    // `NotAMemberStanding`, whose `role` is null) and the reinstalled-phone
    // "this device cannot say" case (`UnknownStanding`, also null) — only an
    // actual, known role belongs on this shelf.
    if (standing.role == null) continue;
    final linked = await ref.watch(
      isProjectLinkedProvider(project.projectId).future,
    );
    if (!linked) unsynced.add(project.projectId);
  }
  return unsynced;
}

/// Publish, discover, and join server projects (task 10.9).
///
/// Deliberately a separate provider from [SyncController]: publishing and
/// joining act on a project the user picks, which is not necessarily the
/// currently *active* one (join in particular targets a project this device
/// has no local copy of yet, so it cannot be "active"). Ongoing sync, by
/// contrast, always operates on the active project. Folding both into one
/// provider would conflate "which project is this action about" with "which
/// project is currently open."
@Riverpod(keepAlive: true)
class ProjectLinkController extends _$ProjectLinkController {
  @override
  void build() {}

  /// Uploads [projectId] in full, idempotently. Safe to call again after a
  /// failure — see `ProjectPublisher`'s doc comment for why a retry never
  /// duplicates anything.
  Future<PublishReport> publish(
    String projectId, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final transport = await _requireTransport();
    final db = await ref.read(appDatabaseProvider.future);
    final report = await ProjectPublisher(
      db: db.raw,
      transport: transport,
      state: ref.read(syncStateStoreProvider),
      deviceId: await ref.read(deviceIdProvider.future),
      userId: await _requireSessionUserId(),
    ).publish(projectId, onProgress: onProgress);
    // The project just became linked, which changes what the sync-status
    // provider (and any per-project "is this linked" watcher) should say.
    ref.invalidate(syncControllerProvider);
    ref.invalidate(isProjectLinkedProvider);
    return report;
  }

  /// Server projects this user belongs to that this device is not syncing —
  /// including any whose local copy is here but deleted or unlinked (task
  /// 11.57). See [ProjectDirectoryClient.listAvailableToJoin].
  Future<List<JoinableProject>> listAvailableToJoin() async {
    final transport = await _requireTransport();
    final db = await ref.read(appDatabaseProvider.future);
    return ProjectDirectoryClient(
      db: db.raw,
      transport: transport,
      state: ref.read(syncStateStoreProvider),
    ).listAvailableToJoin();
  }

  /// Server projects this user deleted from a device that the server still
  /// holds as tombstones (task 11.292). See
  /// [ProjectDirectoryClient.listDeletedOnServer].
  Future<List<DeletedProjectSummary>> listDeletedOnServer() async {
    final transport = await _requireTransport();
    final db = await ref.read(appDatabaseProvider.future);
    return ProjectDirectoryClient(
      db: db.raw,
      transport: transport,
      state: ref.read(syncStateStoreProvider),
    ).listDeletedOnServer();
  }

  /// Attaches this device to [projectId] and pulls its full history.
  Future<SyncRunReport> join(
    String projectId, {
    void Function(SyncProgress)? onProgress,
  }) async {
    final transport = await _requireTransport();
    final db = await ref.read(appDatabaseProvider.future);
    final report = await ProjectJoiner(
      db: db.raw,
      transport: transport,
      state: ref.read(syncStateStoreProvider),
      deviceId: await ref.read(deviceIdProvider.future),
      userId: await _requireSessionUserId(),
    ).join(projectId, onProgress: onProgress);
    // A brand-new local Projects row exists now; every screen that lists
    // local projects needs to see it.
    ref.invalidate(allProjectsProvider);
    ref.invalidate(syncControllerProvider);
    ref.invalidate(isProjectLinkedProvider);
    // A join is the largest arrival there is — a whole project's worth of
    // observations that no screen asked for. The screens are told by
    // `ProjectMerger`, which every pulled page passes through; see
    // `DataArrival` for why that announcement is not made here (task 11.45).
    return report;
  }

  /// The signed-in user id both `ProjectPublisher` and `SyncEngine` need since
  /// task 11.43, thrown for on the same condition [_requireTransport] throws on
  /// — there is no such thing as a publish or a join without a session.
  Future<String> _requireSessionUserId() async {
    final session = await ref.read(currentSessionProvider.future);
    if (session == null) throw const SyncTransportException('not_configured');
    return session.userId;
  }

  /// The connection, from the app's one seam (task 11.97).
  ///
  /// The address check that used to be written out here now lives inside
  /// [requireServerTransport], for the reason it was written here in the
  /// first place: it was the third copy of it, and the two providers this
  /// controller sits beside had the other two.
  Future<SyncTransport> _requireTransport() => requireServerTransport(ref);
}

/// What one read of [deletedOnServerListingProvider] produced (task 11.313).
class DeletedOnServerListing {
  const DeletedOnServerListing({required this.projects, required this.failure});

  final List<DeletedProjectSummary> projects;

  /// Why the list could not be read, or null. A server that does not offer
  /// the route (task 11.307) lands here too, rather than being swallowed.
  final Object? failure;
}

/// **Projects this person deleted in the app that the server still holds**
/// — the section `ProjectsScreen` shows at the bottom (task 11.313, moved
/// from `JoinProjectScreen`'s original home in task 11.292).
///
/// Gated on [canUseServer]: the same "is there a server, and are we signed
/// in" test the screens already compute to decide whether to show the
/// affordance at all, asked here too so a device with neither reaches no
/// server and throws nothing through [ProjectLinkController._requireTransport].
///
/// **Not `@riverpod`-generated.** A plain `FutureProvider.autoDispose`, the
/// same hand-written shape `deployments_provider.dart` and
/// `individuals_provider.dart` already use in this package — this needed no
/// family and no code generation, so it does not ask for either.
final deletedOnServerListingProvider =
    FutureProvider.autoDispose<DeletedOnServerListing>((ref) async {
  final canUseServer =
      (ref.watch(serverConfigProvider).value?.isConfigured ?? false) &&
      ref.watch(currentSessionProvider).value != null;
  if (!canUseServer) {
    return const DeletedOnServerListing(projects: [], failure: null);
  }
  try {
    final deleted = await ref
        .read(projectLinkControllerProvider.notifier)
        .listDeletedOnServer();
    return DeletedOnServerListing(projects: deleted, failure: null);
  } catch (e) {
    return DeletedOnServerListing(projects: const [], failure: e);
  }
});

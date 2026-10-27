import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/sync/pending_project_change.dart';
import '../../data/sync/project_deletion_notice.dart';
import '../../data/sync/project_trash.dart';
import '../../data/sync/sync_failure.dart';
import '../../data/sync/sync_held_rows.dart';
import '../../data/sync/sync_transport.dart';
import 'app_context_provider.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'device_id_provider.dart';
import 'project_link_provider.dart';
import 'server_transport_provider.dart';
import 'sync_provider.dart';

part 'project_deletion_provider.g.dart';

/// **Where each project's scheduled deletion stands, as this device last
/// heard it** (task 11.290) — keyed by project id.
///
/// The Projects list draws its countdowns from this. It is read from
/// `SyncStateStore` so the list is right offline, and refreshed from
/// `GET /projects/mine` whenever a person is looking at the list — on
/// opening it, on pull-to-refresh, and when the app comes to the foreground.
///
/// ## Who writes it
///
/// - [refreshFromServer]: every project the directory lists gets the date it
///   carries, or has its notice removed when it carries none (the owner
///   canceled). A project the directory *no longer lists* while this device
///   is still counting it down is **asked about directly** — one pull of one
///   row — because from the listing alone the device cannot tell "destroyed"
///   from "I was removed", and only the server's named refusal settles it.
///   Michael's device look (2026-09-20) found the gap: the sweep ran, the
///   project left the listing, and the row on a phone that did not have that
///   project open went on saying the date had passed unconfirmed, because
///   the only thing that had ever asked the server *about that project* was
///   its own sync round.
/// - [markDestroyed]: the server refused the project with
///   `project_destroyed`, or the owner's own *delete now* ran on this device.
///   The row then says the project is gone from the server, rather than
///   counting down past zero.
/// - [act]: the owner scheduled, canceled or destroyed from this device, and
///   the server's answer is written straight in so the row moves at once.
@Riverpod(keepAlive: true)
class ProjectDeletionNotices extends _$ProjectDeletionNotices {
  @override
  Future<Map<String, ProjectDeletionNotice>> build() =>
      ref.watch(syncStateStoreProvider).deletionNotices();

  /// Whether this device holds a notice that is still counting down — the
  /// foreground gate in `app.dart`, read from the store rather than from
  /// this provider's state so a lifecycle hook never has to wait on a build.
  Future<bool> holdsACountdown() async {
    final held = await ref.read(syncStateStoreProvider).deletionNotices();
    return held.values.any((notice) => !notice.executed);
  }

  /// Asks the server which of this person's projects are scheduled, and
  /// writes the answer down. **Never throws**: every caller is a lifecycle
  /// hook or a refresh gesture with nowhere to put an exception, and a server
  /// out of reach is the ordinary field condition rather than an error. The
  /// list keeps what it last knew.
  Future<void> refreshFromServer() async {
    final SyncTransport transport;
    try {
      transport = await requireServerTransport(ref);
    } on SyncTransportException {
      return;
    }
    if (!ref.mounted) return;
    final List<ProjectSummary> listed;
    try {
      listed = await transport.listMyProjects();
    } on SyncTransportException {
      return;
    } catch (_) {
      return;
    }
    if (!ref.mounted) return;
    final store = ref.read(syncStateStoreProvider);
    final now = DateTime.now().toUtc();
    var changed = false;
    final current = await store.deletionNotices();
    for (final project in listed) {
      final destroyAt = project.destroyAt;
      final held = current[project.projectId];
      if (destroyAt == null) {
        // Listed with no date: not scheduled, or the owner canceled. Either
        // way the countdown comes down. An `executed` notice cannot be listed
        // — a destroyed project has no membership rows to list it by — so
        // this never erases one.
        if (held != null && !held.executed) {
          await store.setDeletionNotice(project.projectId, null);
          changed = true;
        }
        continue;
      }
      if (held?.executed == true) continue;
      await store.setDeletionNotice(
        project.projectId,
        ProjectDeletionNotice(destroyAt: destroyAt, learnedAt: now),
      );
      changed = true;
    }
    // Counting down, and no longer listed: ask. A pull of one row from
    // cursor zero is the cheapest request every sync route answers by name
    // for a destroyed project, and it writes nothing on either side — a
    // refused pull is never acknowledged. `forbidden` (this person was
    // removed) and anything else leave the notice as it is.
    final listedIds = {for (final project in listed) project.projectId};
    for (final entry in current.entries) {
      final projectId = entry.key;
      if (entry.value.executed || listedIds.contains(projectId)) continue;
      if (await _confirmDestroyed(transport, projectId)) {
        if (!ref.mounted) return;
        await markDestroyed(projectId, destroyAt: entry.value.destroyAt);
        changed = true;
      }
    }
    if (changed || listed.isNotEmpty) _reload();
  }

  /// Asks the server whether [projectId] is destroyed and, if it is, records
  /// it exactly as [refreshFromServer] would. For a refusal that cannot say
  /// why by itself — the owner's *restore* (task 11.302) is answered `403
  /// forbidden` for a destroyed project, as for any project the caller may
  /// not act on, and the route deliberately does not name it. **Pull does**,
  /// under §4.13's existing written exception, so the app asks pull rather
  /// than widening the exception to a second route. Never throws.
  Future<bool> confirmDestroyed(String projectId) async {
    final SyncTransport transport;
    try {
      transport = await requireServerTransport(ref);
    } catch (_) {
      return false;
    }
    if (!await _confirmDestroyed(transport, projectId)) return false;
    if (!ref.mounted) return true;
    await markDestroyed(projectId);
    return true;
  }

  /// Whether the server names [projectId] as destroyed. False for every other
  /// answer, including no answer.
  Future<bool> _confirmDestroyed(
    SyncTransport transport,
    String projectId,
  ) async {
    try {
      final deviceId = await ref.read(deviceIdProvider.future);
      await transport.pull(
        SyncPullRequest(
          projectId: projectId,
          deviceId: deviceId,
          cursor: 0,
          batchSize: 1,
        ),
      );
      return false;
    } on SyncTransportException catch (error) {
      return error.reason == syncRefusalProjectDestroyed;
    } catch (_) {
      return false;
    }
  }

  /// Records that [projectId] is gone from the server — learned from the
  /// server's own refusal, or from an owner's *delete now* here.
  ///
  /// Also unlinks the project: a destroyed project has nothing left to sync
  /// with, and a linked one would keep offering its rows to a refusal —
  /// task 11.289's foreground flush retries a pending `Projects` row on every
  /// foreground for as long as the project stays linked. Only sync
  /// bookkeeping is cleared; every record stays, which is Michael's decision
  /// and the whole point of the row this feeds.
  Future<void> markDestroyed(String projectId, {DateTime? destroyAt}) async {
    final store = ref.read(syncStateStoreProvider);
    final now = DateTime.now().toUtc();
    final held = await store.deletionNotice(projectId);
    await store.setDeletionNotice(
      projectId,
      (held ??
              ProjectDeletionNotice(
                destroyAt: destroyAt ?? now,
                learnedAt: now,
              ))
          .markExecuted(now),
    );
    if (await store.isProjectLinked(projectId)) {
      await store.clear(projectId);
      ref.invalidate(isProjectLinkedProvider);
    }
    _reload();
  }

  /// Where [projectId]'s deletion stands on the server, with the grace period
  /// the server would apply — asked before the owner is shown the dialog, so
  /// the number in it is the server's. Throws the transport's refusal when
  /// there is no server to ask; the caller says so.
  Future<ProjectDeletionStanding> standing(String projectId) async {
    final transport = await requireServerTransport(ref);
    return transport.projectDeletion(projectId);
  }

  /// The owner's act — schedule, delete now, or cancel — sent to the server,
  /// with the server's answer written into this device's notice so the row
  /// moves at once rather than on the next refresh.
  Future<ProjectDeletionStanding> act(
    String projectId,
    ProjectDeletionAction action,
  ) async {
    final transport = await requireServerTransport(ref);
    final standing = await transport.setProjectDeletion(projectId, action);
    if (!ref.mounted) return standing;
    if (standing.executedAt != null) {
      await markDestroyed(projectId, destroyAt: standing.destroyAt);
    } else {
      final store = ref.read(syncStateStoreProvider);
      final destroyAt = standing.destroyAt;
      await store.setDeletionNotice(
        projectId,
        destroyAt == null
            ? null
            : ProjectDeletionNotice(
                destroyAt: destroyAt,
                learnedAt: DateTime.now().toUtc(),
              ),
      );
      _reload();
    }
    return standing;
  }

  void _reload() {
    if (!ref.mounted) return;
    ref.invalidateSelf();
  }
}

/// **The refusal the last delivery attempt for a project's own row met**,
/// keyed by project id (task 11.290, folding in task 11.289's open question).
///
/// `SyncController.deliverPendingProjectChanges` runs one round per stranded
/// `Projects` row and swallows every failure — correctly, because "delivered"
/// is decided from the pending set and not from the round. What it could not
/// do was *say* anything: an owner whose deletion the server refused (the
/// project records somebody else as owner; a build too old) believed the
/// project gone while it stayed live for the team, and nothing anywhere
/// showed the refusal. This is where the round writes the cause, so the
/// Projects list can put a row on screen saying **the server has not accepted
/// this deletion**. Cleared when the row is finally delivered, or when the
/// device gives up on it (the project is unlinked).
@Riverpod(keepAlive: true)
class ProjectChangeRefusals extends _$ProjectChangeRefusals {
  @override
  Map<String, SyncFailureCause> build() => const {};

  void record(String projectId, SyncFailureCause cause) {
    state = {...state, projectId: cause};
  }

  void forget(String projectId) {
    if (!state.containsKey(projectId)) return;
    state = {
      for (final entry in state.entries)
        if (entry.key != projectId) entry.key: entry.value,
    };
  }
}

/// A project deleted on this device whose tombstone the server has not yet
/// confirmed — and, when the last attempt was refused, why.
///
/// A refusal reaches this row by two routes, and task 11.289 found the second
/// one is the common one: **a whole-request `403`** (the person has no
/// relationship to the project on the server), remembered in
/// [ProjectChangeRefusals]; or **a per-row `unauthorized`** on a `200` (the
/// person is on the project but the server does not record them as its
/// owner), which the engine puts in the held-row store — and a held row is
/// no longer pending, so the flush correctly stops offering it and nothing
/// else would ever have shown it.
class UndeliveredProjectDeletion {
  const UndeliveredProjectDeletion({
    required this.projectId,
    required this.projectName,
    required this.deletedAt,
    required this.refusal,
    required this.held,
  });

  final String projectId;
  final String projectName;
  final DateTime? deletedAt;

  /// Null while the row is merely waiting for signal; a cause once the server
  /// has answered the whole request and said no.
  final SyncFailureCause? refusal;

  /// The held-row record, when the server refused this one row and the
  /// engine set it aside.
  final HeldRow? held;

  bool get wasRefused =>
      held != null ||
      (refusal != null &&
          refusal != SyncFailureCause.unreachable &&
          refusal != SyncFailureCause.timedOut);
}

/// **Every project deleted here that is still live on the server as far as
/// this device knows** — task 11.289's own recommendation, built as a row on
/// the Projects list rather than a retry.
///
/// Derived from the same predicate the push runs (`findUndeliveredProjectChanges`
/// → `SyncEngine.wouldOffer`), narrowed to tombstones, and joined with the
/// refusal memory above. A deleted project is otherwise invisible on every
/// screen, so this is the one place the person who deleted it can learn it
/// did not take.
@riverpod
Future<List<UndeliveredProjectDeletion>> undeliveredProjectDeletions(
  Ref ref,
) async {
  final session = await ref.watch(currentSessionProvider.future);
  if (session == null) return const [];
  final db = await ref.watch(appDatabaseProvider.future);
  final store = ref.watch(syncStateStoreProvider);
  final refusals = ref.watch(projectChangeRefusalsProvider);
  final pending = {
    for (final change in await findUndeliveredProjectChanges(
      db: db.raw,
      state: store,
      userId: session.userId,
    ))
      if (change.isDeletion) change.projectId,
  };
  // Every tombstoned project this device is linked to. The pending ones are
  // waiting (or were refused as a whole); the rest are only here if the
  // engine holds their tombstone after a per-row refusal.
  final tombstones = await db.raw.query(
    Tables.projects,
    columns: ['project_id', 'project_name', 'deleted_at'],
    where: 'deleted_at IS NOT NULL',
  );
  await SyncHeldRowStore.ensureTable(db.raw);
  final heldStore = SyncHeldRowStore(db.raw);
  final out = <UndeliveredProjectDeletion>[];
  for (final row in tombstones) {
    final projectId = row['project_id'] as String;
    if (!await store.isProjectLinked(projectId)) continue;
    HeldRow? held;
    if (!pending.contains(projectId)) {
      for (final candidate in await heldStore.held(projectId)) {
        if (candidate.tableName == Tables.projects &&
            candidate.rowKey == projectId) {
          held = candidate;
          break;
        }
      }
      if (held == null) continue;
    }
    out.add(
      UndeliveredProjectDeletion(
        projectId: projectId,
        projectName: row['project_name'] as String? ?? '',
        deletedAt: DateTime.tryParse(row['deleted_at'] as String? ?? ''),
        refusal: refusals[projectId],
        held: held,
      ),
    );
  }
  return out;
}

/// **Projects this person moved to the Trash that this phone does not sync**
/// (task 11.339, item 1) — the Trash rows the server cannot list, because it
/// never held them, or because this phone no longer syncs them.
///
/// The third source of the Projects screen's Trash section, beside
/// [undeliveredProjectDeletionsProvider] (moved to the Trash here, not sent
/// yet) and the server's own listing. The three cannot name the same project:
/// the first two need a linked project and this one an unlinked one, and the
/// screen drops any id the server listing also names.
///
/// **Needs no server and no session**: the case it exists for is a phone
/// that has never published anything. Every `ref.watch` is issued before the
/// first `await` (task 11.236). A plain `FutureProvider.autoDispose`, like
/// `deletedOnServerListingProvider`: it needs no family and no code
/// generation.
final trashedOnThisDeviceProvider =
    FutureProvider.autoDispose<List<TrashedHere>>((ref) async {
      final dbFuture = ref.watch(appDatabaseProvider.future);
      final userFuture = ref.watch(currentUserProvider.future);
      final store = ref.watch(syncStateStoreProvider);
      final db = await dbFuture;
      final user = await userFuture;
      return ProjectTrash.onThisDevice(
        db.raw,
        userId: user.userId,
        isLinked: store.isProjectLinked,
      );
    });

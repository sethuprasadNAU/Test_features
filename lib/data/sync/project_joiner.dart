import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'sync_engine.dart';
import 'sync_state_store.dart';
import 'sync_transport.dart';

/// Attaches this device to an already-published project (task 10.9).
///
/// ## Why there is almost no new logic here
///
/// Bringing down a project this device has never seen is not a special case
/// of sync — it **is** sync, just starting from cursor zero, which is exactly
/// the "phone joining a project with a season of data" scenario task 10.7's
/// chunking was built for and task 10.8's [SyncEngine] already implements: it
/// pages until exhausted, commits each page before advancing, and resumes from
/// wherever it stopped if interrupted. Reimplementing any of that here would
/// be a second, untested copy of behaviour the engine already has to get
/// right.
///
/// The only genuinely new piece is **discovering what there is to join** — the
/// device has no local row for a project it has never synced, so it cannot ask
/// its own database. That is [ProjectDirectoryClient.listAvailableToJoin],
/// which is what task 10.9 actually adds.
class ProjectJoiner {
  const ProjectJoiner({
    required this.db,
    required this.transport,
    required this.state,
    required this.deviceId,
    required this.userId,
  });

  final Database db;
  final SyncTransport transport;
  final SyncStateStore state;
  final String deviceId;

  /// The signed-in user, passed straight through to [SyncEngine] — see its own
  /// field for why the engine needs one.
  final String userId;

  /// Joins [projectId]: marks it linked, then runs an ordinary sync from
  /// cursor zero.
  ///
  /// A tombstone this device wrote on its own copy of [projectId] is cleared
  /// first — see [_withdrawLocalTombstone] for the defect that needs.
  ///
  /// Marking linked *before* the pull, unlike publish's mark-linked-*after*.
  /// The two are not inconsistent — each protects against the failure that
  /// actually threatens it. Publish marks last so an interrupted upload is
  /// never mistaken for a complete one. Join marks first because the pull that
  /// follows is itself fully resumable (10.7/10.8): an interruption here
  /// leaves the cursor wherever it stopped, and the *next* sync — automatic or
  /// manual — simply continues it, exactly like recovering from a dropped
  /// connection mid-sync ever after. There is no analogous "was this fully
  /// downloaded" question to protect against.
  Future<SyncRunReport> join(
    String projectId, {
    int batchSize = defaultSyncBatchSize,
    void Function(SyncProgress)? onProgress,
  }) async {
    await state.markProjectLinked(projectId);
    await _withdrawLocalTombstone(projectId);
    return SyncEngine(
      db: db,
      transport: transport,
      state: state,
      deviceId: deviceId,
      userId: userId,
    ).run(projectId, batchSize: batchSize, onProgress: onProgress);
  }

  /// **Withdraws a tombstone this device wrote before the grant** (2026-08-29).
  ///
  /// Confirmed by Michael on real hardware: leave a project, delete your copy
  /// of it, get back onto it — and the project comes back **invisible**.
  /// Nothing errors and the sync reports success.
  ///
  /// **Why the pull cannot fix it by itself.** Deleting a project writes a
  /// tombstone on the local `Projects` row and, like every soft delete here,
  /// bumps its `revision`. `MergeResolver.compare` reads revision *before*
  /// timestamp, so that local row now outranks the server's copy of the same
  /// project. The join pulls the server's row, the merge correctly declines to
  /// overwrite a newer local one, and the tombstone survives every future sync
  /// until the owner happens to edit the project twice.
  ///
  /// **Why here and not in the delete.** The clock bump is not wrong: it is
  /// what every soft delete does, and no device ever offers a `Projects` row to
  /// the server (`offer_rules.dart`), so it has no outbound consequence at all.
  /// What is wrong is that a *local visibility choice* outranked the server on
  /// the way back in. Joining is this device's explicit, later statement that
  /// it wants the project here, so this is where the earlier one is withdrawn.
  ///
  /// **`deleted_at` only, and the clock deliberately left alone.** Restoring
  /// through `BaseRepository.restoreByKey` would bump the revision *again* and
  /// put the local row two ahead of the server, which lengthens exactly the
  /// staleness this is trying to end. Clearing the one column undoes the one
  /// thing the local action set. The residue, stated rather than hidden: if the
  /// owner edited the project exactly once between the person leaving and
  /// rejoining, the rejoining device can show that project's name and extent
  /// one edit behind until the next owner edit. Content, never visibility, and
  /// self-correcting.
  ///
  /// Written raw rather than through `ProjectRepository`, as every other write
  /// in this layer is (`ProjectMerger._upsert`): a departed member is not an
  /// owner, and the authorization for this is the grant the server has just
  /// made — which is the thing that caused this call.
  Future<int> _withdrawLocalTombstone(String projectId) => db.update(
    Tables.projects,
    {'deleted_at': null},
    where: 'project_id = ? AND deleted_at IS NOT NULL',
    whereArgs: [projectId],
  );
}

/// Discovers which server projects this device could join.
class ProjectDirectoryClient {
  const ProjectDirectoryClient({
    required this.db,
    required this.transport,
    required this.state,
  });

  final Database db;
  final SyncTransport transport;

  /// Read for one thing only: whether this device is actually *syncing* a
  /// project it holds a copy of. See [listAvailableToJoin].
  final SyncStateStore state;

  /// Every project the server considers to belong to the signed-in user,
  /// **except the ones this device is already holding and syncing**.
  ///
  /// ## What "already has it" has to mean, and what it used to mean
  ///
  /// A project already on this device and syncing is excluded, and not offered
  /// as something to join: offering a second "join" action for it would invite
  /// exactly the confusion the plan is careful to rule out elsewhere — two
  /// distinct ids that merely share a name are two projects, and conversely,
  /// one id already present and live locally is one project, not a second
  /// thing to attach.
  ///
  /// **Until task 11.57 the test was "is there a local row with this id",
  /// nothing more, and that locked a device out of a project it belonged
  /// to.** Michael reached it on 2026-08-29: he left a project on his iPhone
  /// and deleted his copy of it, the departure had not reached the server, and
  /// so the Mac's fresh invitation was correctly refused — *"you're already on
  /// that project"* — while the project itself was excluded from this list,
  /// because a **tombstoned** local row still counted as "already have it".
  /// There was no route back to it from that device at all, and nothing on the
  /// device said so.
  ///
  /// Three conditions now, all three required to exclude, and each of them is
  /// a way a person can be a member of a project their device is not showing
  /// them:
  ///
  /// 1. **A local row exists.** Unchanged.
  /// 2. **It is not tombstoned.** A deleted local copy is invisible on every
  ///    screen in the app, so "you already have it" is false in the only sense
  ///    the person can check.
  /// 3. **The project is linked** — this device is syncing it
  ///    ([SyncStateStore.isProjectLinked]). An unlinked local copy receives
  ///    nothing and sends nothing; the sync surface says nothing about it
  ///    either, because "never published" and "no longer syncing" are the same
  ///    silence there. A copy is left unlinked without anybody deleting
  ///    anything whenever this device learned it was off the project — an
  ///    owner removed this person and later readmitted them, say
  ///    (`SyncStateStore.clear` is what unlinks; sign-out does not, task
  ///    11.304).
  ///
  /// **Joining an already-present project relinks the copy that is here — it
  /// does not fetch a fresh one over the top of it.** That is
  /// [ProjectJoiner.join]'s doing, and it is the half of this fix that matters
  /// for anybody with records on the device: the tombstone is withdrawn, the
  /// project is marked linked, and the ordinary sync round that follows pushes
  /// whatever was waiting. Nothing on the device is discarded to get it back.
  Future<List<JoinableProject>> listAvailableToJoin() async {
    final remote = await transport.listMyProjects();
    final offers = <JoinableProject>[];
    for (final project in remote) {
      final held = await _localCopy(project.projectId);
      final syncing =
          held != null &&
          held['deleted_at'] == null &&
          await state.isProjectLinked(project.projectId);
      if (syncing) continue;
      offers.add(
        JoinableProject(
          project: project,
          alreadyOnThisDevice: held != null,
        ),
      );
    }
    return offers;
  }

  /// Every project this person deleted from a device that the server still
  /// holds as a tombstone (task 11.292) — owner only, by the server's rule.
  ///
  /// Nothing is filtered here. Whether this device holds a (tombstoned) copy
  /// changes nothing about what the row is for: the project is gone from
  /// every screen either way, its records are still on the server, and the
  /// one thing offered is to delete it from the server. The join screen
  /// shows these in their own section, not among the joinable rows — a
  /// tombstoned project is not something to join.
  Future<List<DeletedProjectSummary>> listDeletedOnServer() =>
      transport.listMyDeletedProjects();

  Future<Map<String, Object?>?> _localCopy(String projectId) async {
    final rows = await db.query(
      Tables.projects,
      columns: ['project_id', 'deleted_at'],
      where: 'project_id = ?',
      whereArgs: [projectId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }
}

/// A project the server says you are on and this device is not syncing —
/// together with **whether the device already holds a copy of it**.
///
/// ## Why the second half is carried to the screen rather than kept here
///
/// The two cases look identical in a list and are not the same action, and the
/// difference is the one a person is entitled to worry about. A project this
/// device has never seen is downloaded. A project it already holds — hidden by
/// a delete, or unlinked when this device learned it was off the project — is
/// **relinked**: the local tombstone is withdrawn, everything already on the
/// device stays exactly where it is, and the sync round that follows pushes
/// whatever was waiting
/// (`ProjectJoiner.join`). Somebody who deleted their copy last week and is
/// looking at a button marked "Join" has no way to know that the records they
/// wrote are about to come back rather than be replaced, and "will this wipe
/// what I had?" is the right question to be asking.
class JoinableProject {
  const JoinableProject({
    required this.project,
    required this.alreadyOnThisDevice,
  });

  final ProjectSummary project;

  /// True when a local `Projects` row for it exists — tombstoned or merely
  /// unlinked. Joining relinks that copy; it does not fetch a fresh one over
  /// the top of it.
  final bool alreadyOnThisDevice;

  String get projectId => project.projectId;
  String get projectName => project.projectName;
}

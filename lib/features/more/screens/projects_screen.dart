import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../../core/errors/failure_message.dart';
import '../../../core/errors/guarded_write.dart';
import '../../../widgets/disabled_reason.dart';

import '../../../core/providers/active_selection_provider.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/providers/database_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/join_request_watcher.dart';
import '../../../core/providers/membership_provider.dart';
import '../../../core/providers/project_deletion_provider.dart';
import '../../../core/providers/project_link_provider.dart';
import '../../../core/providers/server_config_provider.dart';
import '../../../core/providers/sync_provider.dart';
import '../../../data/models/project.dart';
import '../../../data/sync/project_deletion_notice.dart';
import '../../../data/sync/project_publisher.dart';
import '../../../data/sync/project_trash.dart';
import '../../../data/sync/sync_transport.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../data/repositories/mutation_authorization.dart';
import '../../../data/repositories/project_membership_repository.dart';
import '../../../widgets/load_failure.dart';
import '../widgets/join_requests_card.dart';
import '../widgets/project_deletion_dialogs.dart';

/// Lists every project on this device, lets the user switch which one is
/// active (tap a row), edit one's setup/extent, delete one (soft-delete +
/// undo, same pattern as observation deletion), or start a new one.
///
/// **Since task 11.290 it is also where a project's deletion from the server
/// is scheduled, seen counting down by every member, canceled, and — after
/// the fact — explained.** Stateful only for the post-frame refresh that asks
/// the server which projects are scheduled when the list is opened.
class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key});

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  String? _restoringDeletedProjectId;

  @override
  void initState() {
    super.initState();
    // **Opening this list is a person looking at the countdown**, so the
    // countdown is asked for. Never throws, and a server out of reach leaves
    // the list drawing what it last knew (task 11.290).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(projectDeletionNoticesProvider.notifier).refreshFromServer();
    });
  }

  /// **Brings back a project this person deleted**, for every member — moved
  /// here unchanged from `JoinProjectScreen` (task 11.302's original home).
  ///
  /// Asks first — the act reaches other people's phones — then sends the
  /// server's `restore`, then fetches the project onto this device if this
  /// device holds it. Every refusal is said in a sentence that names what is
  /// true and what the person can do; none of them leaves anything changed.
  Future<void> _restoreDeletedProject(DeletedProjectSummary project) async {
    final name = project.projectName;
    final confirmed = await showRestoreProjectDialog(
      context,
      projectName: name,
      destroyAt: project.destroyAt,
    );
    if (!confirmed || !mounted) return;
    final notices = ref.read(projectDeletionNoticesProvider.notifier);
    final sync = ref.read(syncControllerProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _restoringDeletedProjectId = project.projectId);
    try {
      // The server's answer, named `answer` rather than `standing`: in this
      // codebase "standing" is a person's standing on a project, and
      // `screen_role_view_test.dart` reads the word as a permission branch.
      final answer = await notices.act(
        project.projectId,
        ProjectDeletionAction.restore,
      );
      if (answer.executedAt != null) {
        // The sweep got there first, between the list being drawn and the
        // tap. `act` has already recorded it as destroyed.
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: Text(_alreadyDestroyed(name)),
          ),
        );
        return;
      }
      final arrivals = await sync.bringBackRestoredProjects(
        onlyProjectId: project.projectId,
      );
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text(
            arrivals.isNotEmpty
                ? '"$name" is restored, and back in your projects. Every '
                      'member gets it back the next time they open TriTrack '
                      'with cell or wifi coverage.'
                : '"$name" is restored on the server, for every member. To '
                      'have it on this device too, use "Join a project" '
                      'above.',
          ),
        ),
      );
    } catch (e) {
      final String sentence;
      if (e is SyncTransportException && e.statusCode == 403) {
        // The route answers a destroyed project exactly as it answers one
        // this account may not restore (§4.13). Pull tells them apart.
        sentence = await notices.confirmDestroyed(project.projectId)
            ? _alreadyDestroyed(name)
            : 'The server would not restore "$name": it no longer records '
                  'this account as the owner who deleted it. Nothing has '
                  'changed.';
      } else if (e is SyncTransportException && e.userMessage != null) {
        sentence = e.userMessage!;
      } else if (e is SyncTransportException && e.statusCode == 400) {
        // A server from before task 11.302 does not know the action. The
        // app cannot read "older build" off a 400, so it says both halves.
        sentence =
            'The server did not accept the request to restore "$name" — it '
            'may be running a build from before restoring existed. Nothing '
            'has changed.';
      } else {
        sentence =
            'Could not reach the server. Nothing has changed — "$name" is '
            'still deleted. Try again when you have cell or wifi '
            'coverage.';
      }
      messenger.showSnackBar(
        SnackBar(duration: const Duration(seconds: 10), content: Text(sentence)),
      );
    } finally {
      if (mounted) {
        setState(() => _restoringDeletedProjectId = null);
        ref.invalidate(deletedOnServerListingProvider);
      }
    }
  }

  static String _alreadyDestroyed(String name) =>
      '"$name" was already deleted from the server, so there is nothing '
      'there to restore. Nothing has changed on this device.';

  /// Schedules, or carries out, the destruction of a project this device has
  /// deleted — the same dialogs, same server, same numbers as a project still
  /// held locally, moved here unchanged from `JoinProjectScreen`.
  Future<void> _deleteDeletedProjectFromServer({
    required String projectId,
    required String name,
  }) async {
    final notices = ref.read(projectDeletionNoticesProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final standing = await notices.standing(projectId);
      if (!mounted) return;
      final action = await showProjectDeletionDialog(
        context,
        projectName: name,
        standing: standing,
      );
      if (action == null) return;
      final result = await notices.act(projectId, action);
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            result.executedAt != null
                ? '"$name" has been removed from the server, and will be out '
                      'of the server\'s backups within '
                      '${result.backupRetentionDays} days.'
                : '"$name" is scheduled for deletion from the server on '
                      '${formatDeletionDate(result.destroyAt)}. Every member '
                      'will see the countdown.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            describeFailure(
              e,
              fallback:
                  'Could not reach the server. Nothing has changed — '
                  '"$name" is exactly as it was. Try again when you have '
                  'cell or wifi coverage.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) ref.invalidate(deletedOnServerListingProvider);
    }
  }

  Future<void> _cancelDeletedProjectDeletion({
    required String projectId,
    required String name,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(projectDeletionNoticesProvider.notifier)
          .act(projectId, ProjectDeletionAction.cancel);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'The deletion of "$name" is canceled. It stays on the server.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            describeFailure(
              e,
              fallback:
                  'Could not reach the server. The deletion is still '
                  'scheduled — try again when you have cell or wifi '
                  'coverage.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) ref.invalidate(deletedOnServerListingProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(allProjectsProvider);
    final activeIdAsync = ref.watch(activeProjectIdProvider);
    final activeId = activeIdAsync.value;
    final ownedAsync = ref.watch(ownedProjectIdsProvider);
    // Task 11.54: a project the signed-in person has left is deletable by
    // them, which is the one case where the delete control is offered to
    // somebody who is not an owner.
    final departedAsync = ref.watch(departedProjectIdsProvider);
    // Task 11.237: a colleague's archive imported by somebody who is not on
    // the team is a read-only snapshot, and this list is where they meet it
    // — so this is where it says so, not only in an import dialog a
    // fortnight ago. Derived on every read; the day their membership row
    // arrives the project leaves this set with no re-import.
    final snapshotsAsync = ref.watch(snapshotProjectIdsProvider);
    // Task 11.238: a project this person is a member of but that has never
    // been linked to a server — `ImportCase.adopt`'s live-but-silent case,
    // and an ordinary never-published local project, which the database
    // cannot tell apart (see `notSyncingYetOwnerDescription`'s doc). Same
    // shelf as the snapshot line above, same derive-per-read shape.
    final unsyncedAsync = ref.watch(unsyncedMemberProjectIdsProvider);
    // Task 11.290: what this device last heard about each project's deletion
    // from the server. Not awaited into the spinner below — an empty map
    // while it loads draws the list as it was before this task, and the
    // countdown lands a frame later, which is the right order for a screen
    // somebody is waiting on.
    final notices =
        ref.watch(projectDeletionNoticesProvider).value ??
        const <String, ProjectDeletionNotice>{};
    // Task 11.290, folding in task 11.289: projects deleted here whose
    // tombstone the server has not confirmed. Same non-blocking shape.
    final undelivered =
        ref.watch(undeliveredProjectDeletionsProvider).value ??
        const <UndeliveredProjectDeletion>[];
    // Publish/join only make sense once there's a server to talk to and
    // someone signed in to own the projects on it — the same gate
    // `ProjectLinkController._requireTransport` enforces server-side, checked
    // here only to decide whether to show the affordance at all.
    final canUseServer =
        (ref.watch(serverConfigProvider).value?.isConfigured ?? false) &&
        ref.watch(currentSessionProvider).value != null;
    // Task 11.313: projects this person deleted in the app that the server
    // still holds — moved here from the join screen, at the bottom, "like a
    // Trash folder." [deletedOnServerListingProvider] asks nothing on a
    // device with no server or no session; not awaited into the spinner
    // above, so the section pops in a frame later, the same non-blocking
    // shape [notices] and [undelivered] already use on this screen. Absent
    // while nothing has loaded, and absent again once it has if there is
    // nothing to show and nothing went wrong — a heading over an empty list
    // is furniture (task 11.292's rule, unchanged).
    final deletedOnServer = ref.watch(deletedOnServerListingProvider).value;
    final serverTrash = deletedOnServer?.projects ?? const [];
    // Task 11.339: projects moved to the Trash on this phone that this phone
    // does not sync — never published, or no longer synced here. The server
    // cannot list them, so before this they appeared nowhere. Same
    // non-blocking shape as the two above. An id the server also lists is
    // the server's row, said once.
    final serverTrashIds = {for (final p in serverTrash) p.projectId};
    final trashedHere = [
      for (final p
          in ref.watch(trashedOnThisDeviceProvider).value ??
              const <TrashedHere>[])
        if (!serverTrashIds.contains(p.projectId)) p,
    ];
    // **One Trash** (task 11.339, item 2): what was moved to the Trash here
    // and not sent yet, what lives only on this phone, and what the server
    // holds, under one heading. Absent when there is nothing in it and
    // nothing went wrong — a heading over an empty list is furniture (task
    // 11.292's rule, unchanged).
    final showTrash =
        undelivered.isNotEmpty ||
        trashedHere.isNotEmpty ||
        serverTrash.isNotEmpty ||
        deletedOnServer?.failure != null;
    Widget trashSection() => _TrashSection(
      undelivered: undelivered,
      trashedHere: trashedHere,
      serverTrash: serverTrash,
      serverFailure: deletedOnServer?.failure,
      restoringProjectId: _restoringDeletedProjectId,
      onUndoUndelivered: (deletion) => _undoLocalDelete(context, deletion),
      onRestoreHere: (project) => _restoreTrashedHere(context, project),
      onDeleteHerePermanently: (project) =>
          _deleteTrashedHerePermanently(context, project),
      onRestore: _restoreDeletedProject,
      onDeleteFromServer: (project) => _deleteDeletedProjectFromServer(
        projectId: project.projectId,
        name: project.projectName,
      ),
      onCancelDeletion: (project) => _cancelDeletedProjectDeletion(
        projectId: project.projectId,
        name: project.projectName,
      ),
    );

    return Scaffold(
      // **No actions.** The way into joining a project used to be an
      // unlabelled cloud icon here whose meaning lived in a `tooltip` — and a
      // touchscreen never shows a tooltip, so on the device this app is
      // actually used on that control had no label at all. The user guide had
      // to write *the cloud icon at the top right* and hope. It is now a
      // labelled row in the list below, where it is also visible in the empty
      // state — which is exactly where somebody holding a join code and no
      // projects is looking. (Task 11.99.)
      appBar: AppBar(title: const Text('Projects')),
      // **Pull-to-refresh, asked for directly by Michael on 2026-08-31**
      // (task 11.83). It is the manual override for the 60-second poll and it
      // is what a person actually reaches for; before this, the only
      // `RefreshIndicator` in the app was on the Sync Status screen, which is
      // not where somebody waiting to be let into a project is looking.
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: projectsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => LoadFailure('your projects', error: e),
          data: (projects) {
            if (projects.isEmpty) {
              // Scrollable even when empty, so the pull gesture still works —
              // and this is exactly the state somebody waiting for their first
              // project is looking at.
              return ListView(
                padding: _listPadding,
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: JoinRequestsCard(),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      // **Both ways in, named** (task 11.99). This state used
                      // to say only "Tap + to create one" — so somebody who
                      // had just been handed a join code by a colleague was
                      // told, on the one screen they were looking at, about
                      // the one route that was not theirs.
                      child: Text(
                        'No projects yet. Tap + to start one, or join a '
                        'colleague\'s project below.',
                      ),
                    ),
                  ),
                  if (canUseServer) const _JoinProjectTile(),
                  // The empty list is exactly where somebody who moved their
                  // only project to the Trash looks for it (task 11.339).
                  if (showTrash) trashSection(),
                ],
              );
            }
            // Task 11.1: ownership is a set of `Project_Memberships` rows, so
            // the answer needs a query rather than a column already in hand.
            // Resolved once for the whole list and rendered only when it is
            // known — showing the list with every owner-only control provisonally
            // disabled, then enabling them a frame later, is worse than waiting.
            final owned = ownedAsync.value;
            final departed = departedAsync.value;
            final snapshots = snapshotsAsync.value;
            final unsynced = unsyncedAsync.value;
            if (owned == null ||
                departed == null ||
                snapshots == null ||
                unsynced == null) {
              return const Center(child: CircularProgressIndicator());
            }
            // **The news lands here, not only on the join screen** (task
            // 11.83). The whole defect was that the truth about an approved
            // request was one screen away from where the person was looking;
            // this is where they are.
            // The one trailing section, the Trash, after the projects.
            final trashIndex = projects.length + 1;
            return ListView.separated(
              padding: _listPadding,
              // One header row, the projects, and — only when there is
              // something in it — the Trash.
              itemCount: projects.length + 1 + (showTrash ? 1 : 0),
              separatorBuilder: (_, i) =>
                  i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
              itemBuilder: (context, index) {
                if (showTrash && index == trashIndex) return trashSection();
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: JoinRequestsCard(),
                      ),
                      // The labelled replacement for the app bar's cloud icon
                      // (task 11.99). Above the projects rather than below
                      // them: a crew joining a second project should not have
                      // to scroll a list to find the way in.
                      if (canUseServer) const _JoinProjectTile(),
                    ],
                  );
                }
                final i = index - 1;
                final project = projects[i];
                final isActive = project.projectId == activeId;
                final isOwner = owned.contains(project.projectId);
                final hasLeft = departed.contains(project.projectId);
                // Somebody who *left* is also not on the project, and the
                // standing says so for both — but their copy is not "someone
                // else's project", and task 11.54's stranded-records warning
                // is the sentence written for them. The snapshot line is for
                // the person who was never on it.
                final isSnapshot =
                    snapshots.contains(project.projectId) && !hasLeft;
                // Task 11.238: only a real, current member belongs on this
                // shelf — `unsynced` already excludes a snapshot holder and a
                // departed member (both resolve to a null role), so no extra
                // guard against `isSnapshot`/`hasLeft` is needed here, but
                // `canUseServer` still is: with no server configured there is
                // no step to name, so nothing is said.
                final notice = notices[project.projectId];
                // A destroyed project is unlinked (see
                // `ProjectDeletionNotices.markDestroyed`), which would put
                // it on the not-syncing-yet shelf with an invitation to
                // publish — and its id is retired on the server. The
                // deletion line replaces that sentence.
                final notSyncingYet =
                    canUseServer &&
                    unsynced.contains(project.projectId) &&
                    !(notice?.executed ?? false);
                final description = project.description;
                final deletionLine = notice == null
                    ? null
                    : describeProjectDeletion(
                        notice,
                        isOwner: isOwner,
                        now: DateTime.now(),
                      );
                final otherLines = <String>[
                  if (isSnapshot) snapshotProjectDescription,
                  if (notSyncingYet)
                    isOwner
                        ? notSyncingYetOwnerDescription
                        : notSyncingYetMemberDescription,
                  if (description != null && description.isNotEmpty)
                    description,
                ];
                final scheme = Theme.of(context).colorScheme;
                final others = otherLines.isEmpty
                    ? null
                    : Text(
                        otherLines.join('\n'),
                        // The snapshot line and the not-syncing-yet line are
                        // each a fact about the project and must survive
                        // whole; the description keeps its one ellipsised
                        // line below it. The two banner lines are mutually
                        // exclusive (one needs a null role, the other a
                        // non-null one), so at most one adds a line beyond the
                        // description's.
                        maxLines: (isSnapshot || notSyncingYet) ? 3 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: deletionLine == null
                            ? null
                            : TextStyle(color: scheme.onErrorContainer),
                      );
                return ListTile(
                  // **The word carries the meaning; the color is the
                  // accelerator** (CLAUDE.md rule 44). A scheduled or
                  // destroyed project is tinted so it is found at a glance in
                  // a long list, and the sentence under the name says what
                  // the tint means.
                  tileColor: notice == null ? null : scheme.errorContainer,
                  leading: Icon(
                    isActive ? Icons.check_circle : Icons.circle_outlined,
                    color: isActive
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: Text(project.projectName),
                  // The deletion line (task 11.290) comes first, above
                  // everything: it is the loudest fact about the row and the
                  // one a person has a deadline on. **No line limit** (task
                  // 11.323): it was given three lines on the guess that it
                  // needed two, and on a 6.1-inch phone it needs four, so the
                  // owner lost "or cancel from ⋮" — the words that say they
                  // can stop it.
                  subtitle: deletionLine == null
                      ? others
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              deletionLine,
                              style: TextStyle(color: scheme.onErrorContainer),
                            ),
                            ?others,
                          ],
                        ),
                  onTap: isActive
                      ? null
                      : () => _switchTo(context, ref, project),
                  trailing: _ProjectRowMenu(
                    project: project,
                    isOwner: isOwner,
                    hasLeft: hasLeft,
                    isSnapshot: isSnapshot,
                    canUseServer: canUseServer,
                    deletionNotice: notice,
                    onScheduleDeletion: () =>
                        _scheduleServerDeletion(context, project),
                    onCancelDeletion: () =>
                        _cancelServerDeletion(context, project),
                    onExport: () => _exportProject(context, project),
                    onDelete: () => _deleteProject(
                      context,
                      ref,
                      project,
                      // **Owners, and people who have left** (task 11.54).
                      //
                      // Until 11.54, somebody who left a project — or was
                      // removed from one — could neither take part in it nor
                      // get rid of it: the leave control correctly disappears
                      // once you are off the project, and delete was greyed out
                      // because they had never been an owner. The project sat
                      // in their list forever with every control disabled.
                      // Nothing in the accepted design required that: the known
                      // limitation says a departed member's copy cannot be
                      // taken *from* them, not that they may not remove it
                      // themselves.
                      hasLeft: hasLeft && !isOwner,
                      // **A snapshot holder, task 11.238** — never a member at
                      // all, so `hasLeft` is false for them and the exemption
                      // above does not reach them either.
                      isSnapshot: isSnapshot,
                      destroyed: notice?.executed ?? false,
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        // Its own hero tag: every tab's "+" is built at once (task 11.323).
        heroTag: 'fab-projects',
        onPressed: () => context.push('/more/project-setup/new'),
        child: const Icon(Icons.add),
      ),
    );
  }

  /// Room at the bottom of both lists for the floating "+" to sit over
  /// nothing (task 11.323). Without it the list ended where the button
  /// began, and on a 6.1-inch phone the last deleted row's ⋮ was under the
  /// "+" with nothing further to scroll to. The button's own height plus the
  /// margin above and below it, so the last row can scroll clear of it.
  static const _listPadding = EdgeInsets.only(
    top: 8,
    bottom: 56 + 2 * kFloatingActionButtonMargin,
  );

  /// What a pull on the projects list actually does (task 11.83).
  ///
  /// Three things, and the middle one is the reason Michael asked for the
  /// gesture at all:
  ///
  /// 1. Re-reads the local project list.
  /// 2. **Asks whether a join request has been approved**, and downloads the
  ///    project if it has. A pull is a person asking, so this reaches the
  ///    server even on a device whose own bookkeeping says there is nothing
  ///    outstanding, and retries a download that failed earlier.
  /// 3. Nudges an ordinary sync, because somebody pulling a list to refresh it
  ///    means "get me up to date" rather than "re-read the database."
  ///
  /// Never throws: both calls swallow their own failures, which is right for a
  /// gesture with nowhere to put an error and a sync surface that already
  /// reports one.
  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(allProjectsProvider);
    await ref.read(joinRequestWatcherProvider.notifier).refresh();
    // Task 11.290: the countdowns, from the server. Never throws.
    await ref.read(projectDeletionNoticesProvider.notifier).refreshFromServer();
    ref.invalidate(undeliveredProjectDeletionsProvider);
    try {
      await ref.read(syncControllerProvider.notifier).syncNow();
    } catch (_) {
      // The sync surface carries what went wrong; a refresh gesture does not.
    }
  }

  /// **What deleting a project you have left actually costs** (task 11.54).
  ///
  /// Written as a function of the real count rather than as fixed copy,
  /// because *"you will lose everything"* and *"you will lose only what never
  /// synced"* lead a person to different decisions and only one of them is
  /// true on any given day. A warning that describes stranded records when
  /// there are none teaches somebody to skip it on the day there are some.
  ///
  /// Three things it has to say, and the first is the one that is sharper than
  /// "this is your only copy":
  ///
  /// 1. **Once you have left, anything on this device that never reached the
  ///    server never will.** Every further attempt is refused, so those rows
  ///    are not merely un-synced, they are permanently un-syncable — and this
  ///    device is the only place they exist.
  /// 2. **Everything that did sync is safe** on the server and on teammates'
  ///    devices, and deleting here does not touch it. Left unsaid, somebody
  ///    reads the first half as "I am about to destroy the project."
  /// 3. **What rejoining later actually brings back**, said here rather than
  ///    discovered. Task 11.54 first wrote *"you get back what the server
  ///    holds, not what this device held"* — which was the plan's sentence for
  ///    a **destructive** delete, and this is not one. Michael confirmed on
  ///    2026-08-29 that rejoining brings the project back whole, records and
  ///    all, once `ProjectJoiner` stopped leaving it invisible. Copy that
  ///    describes a mechanism the code does not have is the same defect as a
  ///    message that names the wrong cause, one layer up.
  String _leftProjectWarning(
    ({int waiting, int refused, bool everSynced}) stranded,
  ) {
    final stuck = stranded.waiting + stranded.refused;
    if (!stranded.everSynced) {
      // **This project has never reached a server**, so every sentence below
      // about teammates' devices and about rejoining would be an invention.
      // The case is real: somebody who handed a local project on to a
      // colleague and closed their own stint is a past member of a project
      // that was only ever here.
      return 'This project has never been on a server, so this device is the '
          'only place its records exist.'
          '\n\n'
          'Deleting hides them, and you can undo it. If this device is wiped '
          'or replaced, they are gone.';
    }
    final buffer = StringBuffer(
      "You're no longer a member, so nothing from this device will reach "
      'the server again.\n\n',
    );
    if (stuck == 0) {
      buffer.write(
        'Everything you recorded here is already on the server. Deleting '
        'removes your copy, not your teammates\'.\n\n',
      );
    } else {
      final one = stuck == 1;
      buffer.write(
        '$stuck ${one ? 'record' : 'records'} on this device never reached '
        'the server, and now never will. If this device is wiped or '
        'replaced, ${one ? 'it is' : 'they are'} gone.\n\n'
        'Everything else is safe on the server. Deleting removes your copy, '
        "not your teammates'.\n\n",
      );
    }
    buffer.write(
      'Deleting hides the project here. You can undo it, and rejoining the '
      'project brings it back.',
    );
    return buffer.toString();
  }

  /// **The delete warning for a read-only snapshot** (task 11.238) — its own
  /// note, because what is actually at risk here is different from either
  /// case above: the project was never really this device's to begin with.
  ///
  /// No stranded-record accounting, unlike [_leftProjectWarning] — a snapshot
  /// refuses every edit (task 11.237), so nothing here was ever waiting to
  /// sync. And no undo-loses-unsynced-work caveat: since nothing was ever
  /// written, there is nothing this copy holds that the project it came from
  /// does not.
  String _snapshotDeleteWarning() =>
      "This is a copy of someone else's project — you were never a member of "
      'it on this device.'
      '\n\n'
      'Deleting removes only this copy; the project is untouched wherever it '
      'actually lives. You can undo this. To join it, ask an owner for the '
      'join code.';

  Future<void> _switchTo(
    BuildContext context,
    WidgetRef ref,
    Project project,
  ) async {
    await ref.read(activeProjectIdProvider.notifier).set(project.projectId);
    ref.invalidate(currentProjectProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Switched to "${project.projectName}"')),
      );
    }
  }

  /// Same confirm + soft-delete + undo-via-SnackBar pattern as observation
  /// deletion (design doc's "destructive actions require confirm + undo").
  ///
  /// [hasLeft] means the person doing this is no longer a member of the
  /// project, so they are deleting it under
  /// [MutationExemption.departedMember] rather than as an owner. **It changes
  /// the warning, and the warning is the point** — see [_leftProjectWarning].
  ///
  /// [isSnapshot] means they were never a member at all — task 11.238's
  /// [MutationExemption.snapshotHolder] — and gets its own warning,
  /// [_snapshotDeleteWarning], for the same reason: what is actually at risk
  /// is different, so what the warning says has to be too.
  Future<void> _deleteProject(
    BuildContext context,
    WidgetRef ref,
    Project project, {
    bool hasLeft = false,
    bool isSnapshot = false,
    bool destroyed = false,
  }) async {
    // **Task 11.324: "Move to Trash", in words only.** Michael: if it only
    // hides the project, why call it delete? The write below is the same soft
    // delete with the same undo. A project the server has already destroyed
    // keeps the old words, because its menu item is *Delete from this device*
    // and there is no Trash on the server for it to sit in.
    final verb = destroyed ? 'Delete' : 'Move to Trash';
    // Counted *before* the dialog, so the warning says what is actually at
    // risk rather than warning as though something is. See
    // `strandedRecordCountProvider`. Not asked for a snapshot: every edit on
    // one is refused (task 11.237), so nothing here was ever stranded — there
    // is nothing to count.
    final stranded = hasLeft
        ? await ref.read(strandedRecordCountProvider(project.projectId).future)
        : null;
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          destroyed
              ? 'Delete "${project.projectName}"?'
              : 'Move "${project.projectName}" to Trash?',
        ),
        content: SingleChildScrollView(
          child: Text(
            isSnapshot
                ? _snapshotDeleteWarning()
                : stranded == null
                ? 'Its observations and estimates are kept but hidden while '
                      'it stays deleted. You can undo this.'
                : _leftProjectWarning(stranded),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(verb),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final repo = await ref.read(projectRepositoryProvider.future);
    final wasActive =
        ref.read(activeProjectIdProvider).value == project.projectId;
    // Named at the call site, and verified inside the repository against this
    // device's own membership rows — see [MutationExemption]. Null for an
    // owner, who needs no exemption.
    final exemption = hasLeft
        ? MutationExemption.departedMember(project.projectId)
        : isSnapshot
        ? MutationExemption.snapshotHolder(project.projectId)
        : null;

    // The Delete affordance is already hidden from non-owners; the refusal only
    // fires if ownership changed (e.g. via merge) between this list rendering
    // and the confirm dialog closing. Task 11.137 moved it onto the shared
    // mechanism and gave it the branch it never had: before, a *failed* delete
    // — as opposed to a refused one — showed nothing at all.
    if (!context.mounted) return;
    final deleted = await runGuardedWrite(
      context,
      write: () => repo.softDeleteById(
        project.projectId,
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
        exemption: exemption,
      ),
      refused: 'Only a project owner can move this project to the Trash.',
      failed:
          'Could not move this project to the Trash; nothing has changed. '
          'Try again, and report it if this keeps happening.',
    );
    if (!deleted) return;
    if (wasActive) {
      await ref.read(activeProjectIdProvider.notifier).set(null);
      ref.invalidate(currentProjectProvider);
    }
    ref.invalidate(allProjectsProvider);
    // The deleted project's row leaves the list, so the two sets the row's
    // controls are rendered from have to be recomputed with it.
    ref.invalidate(departedProjectIdsProvider);
    // And it arrives in the Trash (task 11.339) — the undelivered list is
    // rebuilt by the delivery attempt below; this one by nothing else.
    ref.invalidate(trashedOnThisDeviceProvider);
    // **Task 11.289.** The tombstone just written is on a project that is no
    // longer — or never was — the open one, so no ordinary sync round will
    // offer it; this is the one row whose deletion destroys the scope that
    // would have pushed it. Offer it now if there is signal. This is an
    // attempt, not the mechanism: it fails silently with no signal, and the
    // app's foreground hook (`app.dart`) carries the row until the server
    // takes it, however long that is. See `pending_project_change.dart`.
    _offerStrandedProjectChanges(ref);

    if (!context.mounted) return;
    // Clear any still-showing snackbar first — otherwise a second delete
    // shortly after the first queues behind it instead of replacing it.
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          destroyed
              ? '"${project.projectName}" deleted'
              : '"${project.projectName}" moved to Trash',
        ),
        duration: const Duration(seconds: 6),
        // Task 11.42: an undo bar with an action defaults to `persist: true`
        // in Material 3 — Flutter's own words, "the snackbar will persist as
        // well" — which makes `duration` above dead: the dismiss timer still
        // runs, but its callback is a no-op while persist is true. That is
        // the whole of "the undo bar never goes away": every one of this
        // app's four undo bars set a duration and never knew it did nothing.
        persist: false,
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            if (!context.mounted) return;
            final restored = await runGuardedWrite(
              context,
              write: () => repo.restoreById(
                project.projectId,
                actor: MutationActor.user(user.userId),
                deviceId: deviceId,
                // The same exemption undoes it. Without this, somebody who
                // left a project could delete it and then be refused their own
                // undo — which is the shape task 11.42 spent a whole task on:
                // an undo control that is offered and does not work.
                exemption: exemption,
              ),
              refused:
                  'You are no longer permitted to change this project, so '
                  'it could not be brought back. Ask a project owner.',
              failed:
                  'Could not bring this project back; it is still deleted. '
                  'Try again, and report it if this keeps happening.',
            );
            if (!restored) return;
            if (wasActive) {
              await ref
                  .read(activeProjectIdProvider.notifier)
                  .set(project.projectId);
              ref.invalidate(currentProjectProvider);
            }
            ref.invalidate(allProjectsProvider);
            ref.invalidate(trashedOnThisDeviceProvider);
            // The undo is the same row changing again; if the tombstone got
            // out in the meantime, the restore is what is stranded now. Same
            // attempt as the delete's (task 11.289). When the project is
            // active again its own round would carry it; when it is not,
            // nothing else would.
            _offerStrandedProjectChanges(ref);
          },
        ),
      ),
    );
  }
  // ---- Deleting from the server (task 11.290) -------------------------------

  /// **The owner schedules the project's destruction on the server** — or,
  /// behind a second confirmation, has it done now.
  ///
  /// Asks the server where the deletion stands *first*, so the dialog quotes
  /// the server's grace period and backup window rather than a number this
  /// app guessed. That read needs the server: scheduling a deletion cannot
  /// work offline any more than joining can, and the failure sentence says so
  /// rather than offering a dialog whose numbers would be inventions.
  Future<void> _scheduleServerDeletion(
    BuildContext context,
    Project project,
  ) async {
    final notices = ref.read(projectDeletionNoticesProvider.notifier);
    final ProjectDeletionStanding standing;
    try {
      standing = await notices.standing(project.projectId);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            // A server from before this feature answers 404, and that
            // arrives with its own `userMessage` (task 11.307) — one that
            // names both things a 404 can mean and does not pick. The
            // sentence this branch used to write for it picked: "it is
            // running a build older than this app", asserted from a status
            // code the app cannot read that way.
            e is SyncTransportException && e.userMessage != null
                ? e.userMessage!
                : 'Could not reach the server to schedule this deletion. '
                      'Nothing has changed — "${project.projectName}" is '
                      'still on the server and on this device. Try again '
                      'when you have cell or wifi coverage.',
          ),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    final action = await showProjectDeletionDialog(
      context,
      projectName: project.projectName,
      standing: standing,
    );
    if (action == null || !context.mounted) return;
    await _actOnServerDeletion(context, project, action);
  }

  /// **The owner withdraws a scheduled destruction.** No confirmation: this
  /// is the recoverable direction, and a person who tapped it by mistake can
  /// schedule again.
  Future<void> _cancelServerDeletion(BuildContext context, Project project) =>
      _actOnServerDeletion(context, project, ProjectDeletionAction.cancel);

  Future<void> _actOnServerDeletion(
    BuildContext context,
    Project project,
    ProjectDeletionAction action,
  ) async {
    final notices = ref.read(projectDeletionNoticesProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final name = project.projectName;
    try {
      final standing = await notices.act(project.projectId, action);
      ref.invalidate(unsyncedMemberProjectIdsProvider);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(switch (action) {
            ProjectDeletionAction.schedule =>
              '"$name" is scheduled for deletion from the server on '
                  '${formatDeletionDate(standing.destroyAt)}. Every member '
                  'will see the countdown. You can cancel it from ⋮ until '
                  'then.',
            ProjectDeletionAction.cancel =>
              'The deletion of "$name" is canceled. It stays on the server '
                  'and keeps syncing.',
            ProjectDeletionAction.immediate =>
              '"$name" has been removed from the server, and will be out of '
                  'the server\'s backups within '
                  '${standing.backupRetentionDays} days. The copy on this '
                  'device is kept — export it from ⋮.',
            // Not offered from this list — a project on it is not deleted —
            // but the switch is over every action the server knows, and a
            // sentence that is true beats a default that is not.
            ProjectDeletionAction.restore =>
              '"$name" is on the server for every member.',
          }),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            e is SyncTransportException && e.userMessage != null
                ? e.userMessage!
                : e is SyncTransportException && e.statusCode == 403
                ? 'The server refused: it records somebody else as the '
                      'owner of "$name", so it cannot be deleted from this '
                      'account. Nothing has changed.'
                : 'Could not reach the server. Nothing has changed — '
                      '"$name" is exactly as it was on the server and on '
                      'this device. Try again when you have cell or wifi '
                      'coverage.',
          ),
        ),
      );
    }
  }

  /// **Export, reachable from the row** (task 11.290's acceptance). The
  /// export screen works on the open project, so this opens the project and
  /// goes there.
  Future<void> _exportProject(BuildContext context, Project project) async {
    await ref.read(activeProjectIdProvider.notifier).set(project.projectId);
    ref.invalidate(currentProjectProvider);
    if (!context.mounted) return;
    context.push('/more/data-export');
  }

  // ---- The Trash for this phone's own projects (task 11.339) ---------------

  /// **Restore, for a project in the Trash that this phone does not sync.**
  /// The same write as the six-second UNDO — the mark comes off and every
  /// record reappears as it was — under the same rule (see
  /// [ProjectTrash.restore]). No confirmation: it is the recoverable
  /// direction, it reaches nobody else's phone, and the project can be moved
  /// to the Trash again.
  Future<void> _restoreTrashedHere(
    BuildContext context,
    TrashedHere project,
  ) async {
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final db = await ref.read(appDatabaseProvider.future);
    if (!context.mounted) return;
    final restored = await runGuardedWrite(
      context,
      write: () => ProjectTrash.restore(
        db.raw,
        project.projectId,
        userId: user.userId,
        deviceId: deviceId,
      ),
      refused:
          'You are no longer permitted to change this project, so it could '
          'not be brought back. Ask a project owner.',
      failed:
          'Could not bring "${project.projectName}" back; it is still in the '
          'Trash. Try again, and report it if this keeps happening.',
    );
    if (!restored) return;
    ref.invalidate(allProjectsProvider);
    ref.invalidate(departedProjectIdsProvider);
    ref.invalidate(trashedOnThisDeviceProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '"${project.projectName}" is restored, and back in your projects.',
          ),
        ),
      );
  }

  /// **Delete permanently, for a project in the Trash that this phone does
  /// not sync** — it is removed from this phone with every record in it.
  ///
  /// The dialog says in plain words what is and is not on a server (Michael,
  /// 2026-10-08: "there is nothing on a server to delete; the dialog says
  /// so"). **No countdown**, unlike the server's *Delete permanently…*: that
  /// countdown exists so every member can see it coming and export, and
  /// nobody else holds this copy. What stands in for it is the Trash itself —
  /// the project has already sat there, restorable — and a dialog that says
  /// it cannot be undone and how to keep a copy first.
  Future<void> _deleteTrashedHerePermanently(
    BuildContext context,
    TrashedHere project,
  ) async {
    final name = project.projectName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "$name" permanently?'),
        content: SingleChildScrollView(
          child: Text(
            project.everOnServer
                ? 'This deletes this phone\'s copy, with every record in it — '
                      'bearings, animals, collars and estimates. It does not '
                      'reach the server or anyone else\'s phone, but anything '
                      'recorded here that never reached the server is lost '
                      'with it. It cannot be undone.\n\n'
                      'To keep a copy, restore it and export it first.'
                : 'It was never published, so nothing of it is on a server. '
                      'This deletes it from this phone, with every record in '
                      'it — bearings, animals, collars and estimates. It '
                      'cannot be undone.\n\n'
                      'To keep a copy, restore it and export it first. A copy '
                      'you already exported or shared as a file is not '
                      'affected.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final user = await ref.read(currentUserProvider.future);
    final db = await ref.read(appDatabaseProvider.future);
    final store = ref.read(syncStateStoreProvider);
    if (!context.mounted) return;
    final deleted = await runGuardedWrite(
      context,
      write: () async {
        await ProjectTrash.deletePermanently(
          db.raw,
          project.projectId,
          userId: user.userId,
          isLinked: await store.isProjectLinked(project.projectId),
        );
        // What this phone remembered about the project outside the database
        // — its sync bookkeeping and any deletion notice — goes with it.
        await store.clear(project.projectId);
        await store.setDeletionNotice(project.projectId, null);
      },
      refused: null,
      failed:
          'Could not delete "$name"; nothing has changed and it is still in '
          'the Trash. Try again, and report it if this keeps happening.',
    );
    if (!deleted) return;
    ref.invalidate(trashedOnThisDeviceProvider);
    ref.invalidate(projectDeletionNoticesProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text('"$name" is deleted from this phone.')),
      );
  }

  /// Brings back a project deleted on this device whose deletion the server
  /// has not accepted — the way out of task 11.289's trap, where the person
  /// believes the project gone and it is live for the team.
  Future<void> _undoLocalDelete(
    BuildContext context,
    UndeliveredProjectDeletion deletion,
  ) async {
    final user = await ref.read(currentUserProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final repo = await ref.read(projectRepositoryProvider.future);
    if (!context.mounted) return;
    final restored = await runGuardedWrite(
      context,
      write: () => repo.restoreById(
        deletion.projectId,
        actor: MutationActor.user(user.userId),
        deviceId: deviceId,
      ),
      refused:
          'You are no longer permitted to change this project, so it '
          'could not be brought back.',
      failed:
          'Could not bring this project back. It is still deleted here '
          '— try again, and report it if it keeps happening.',
    );
    if (!restored) return;
    ref.read(projectChangeRefusalsProvider.notifier).forget(deletion.projectId);
    ref.invalidate(allProjectsProvider);
    ref.invalidate(undeliveredProjectDeletionsProvider);
    _offerStrandedProjectChanges(ref);
  }
}

/// An immediate attempt to deliver a project row that no ordinary round can
/// reach — after a delete or an undo on this list (task 11.289).
///
/// Not awaited: it is a network round on somebody else's schedule, and the
/// list has nothing to show about it — the project is hidden, or restored,
/// either way already drawn. Every failure is swallowed on purpose: no signal
/// is the ordinary case this method is *not* the answer to, and the
/// foreground hook asks again. `SyncController` is `keepAlive`, so the
/// notifier outlives this screen; only the lookup has to happen while `ref`
/// is live, which is why the read is synchronous and first.
void _offerStrandedProjectChanges(WidgetRef ref) {
  final controller = ref.read(syncControllerProvider.notifier);
  controller.deliverPendingProjectChanges().catchError((Object _) => 0);
}

/// **The way into joining a project, in words** (task 11.99).
///
/// It used to be an `IconButton` in the app bar carrying a bare
/// `cloud_download` glyph, with "Join a project" in its `tooltip`. **A
/// touchscreen never shows a tooltip**, so on a phone — the device this app is
/// built for — that control had no label at all. The user guide had to describe
/// it as *the cloud icon at the top right* and hope the reader recognised it.
///
/// So it is a labelled row instead, and it is rendered in the empty state too:
/// somebody who has just been handed a join code by a colleague has no
/// projects, and the empty list is the only screen they are looking at.
class _JoinProjectTile extends StatelessWidget {
  const _JoinProjectTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.cloud_download_outlined),
      title: const Text('Join a project'),
      subtitle: const Text(
        'Ask to join a colleague\'s project with the code they give you.',
      ),
      onTap: () => context.push('/more/projects/join'),
    );
  }
}

/// What a project's row offers, one entry per action.
enum _ProjectAction {
  publish,
  members,
  edit,
  newSeason,
  export,
  leave,
  scheduleDeletion,
  cancelDeletion,
  delete,
}

/// **Every action on a project's row, each with a written label** (task 11.99).
///
/// ## What this replaces, and why it is not a polish change
///
/// Each row used to end in up to five bare `IconButton`s — publish, leave,
/// members, edit, delete — whose meanings lived entirely in `tooltip`s. **A
/// touchscreen never shows a tooltip.** So on a phone the row was four or five
/// unlabelled glyphs, and two of them sat side by side: **leave the project**,
/// which is recoverable, and **delete the project**, which is the most
/// destructive thing on the screen. Two unlabelled neighbours where one is
/// recoverable and the other is not is a data-loss shape, not an aesthetic one.
///
/// The menu fixes both halves at once, and it is worth being explicit that they
/// are two separate fixes:
///
/// 1. **Every action now carries text**, visible without hovering, on every
///    platform. The overflow glyph itself stays unlabelled and that is
///    deliberate — a three-dot button is an affordance people already know, and
///    unlike a cloud it promises nothing in particular, so nothing about it can
///    be misread.
/// 2. **Leave and delete are no longer adjacent.** Delete is last, below a
///    divider of its own, drawn in the error colour. Adjacency was doing real
///    work in the old row: the two glyphs were the same size, the same weight
///    and one tap apart.
///
/// ## Why a menu rather than five labelled buttons
///
/// A row of five text buttons does not fit a phone, and wrapping them would
/// push the project's own name off its line. The cost of a menu is one extra
/// tap on every action; the cost of the row was that nobody could tell the
/// actions apart. `ProjectMembersScreen` deliberately keeps its actions
/// unmenued for the opposite reason — it is used under time pressure with a
/// field tech waiting — and that trade is different because those controls are
/// already labelled and none of them destroys a project.
///
/// ## Disabled with the reason on the item, not in a tooltip
///
/// Task 11.12's rule is *explain, don't hide*, and the old row honoured it in a
/// `Tooltip` — which is to say, not on a phone. A disabled item here carries
/// its reason as a second line, so "why is Leave grey" is answered in the place
/// somebody asks it.
class _ProjectRowMenu extends ConsumerStatefulWidget {
  const _ProjectRowMenu({
    required this.project,
    required this.isOwner,
    required this.hasLeft,
    required this.isSnapshot,
    required this.canUseServer,
    required this.deletionNotice,
    required this.onScheduleDeletion,
    required this.onCancelDeletion,
    required this.onExport,
    required this.onDelete,
  });

  final Project project;
  final bool isOwner;
  final bool hasLeft;

  /// Never a member at all (task 11.238) — the third way Delete can be
  /// offered to somebody who is not an owner, alongside [hasLeft].
  final bool isSnapshot;
  final bool canUseServer;

  /// What this device last heard about the project's deletion from the
  /// server, or null (task 11.290). Decides which of *Delete from server…*,
  /// *Cancel scheduled deletion* and *Export records* the menu offers.
  final ProjectDeletionNotice? deletionNotice;

  /// The three server-deletion actions live on [ProjectsScreen] with the
  /// local delete, for the same reason it does: the dialogs and the snackbars
  /// are the screen's.
  final VoidCallback onScheduleDeletion;
  final VoidCallback onCancelDeletion;
  final VoidCallback onExport;

  /// Deleting stays on [ProjectsScreen] — it owns the confirm dialog, the
  /// stranded-record count that warning is computed from, and the undo bar.
  final VoidCallback onDelete;

  @override
  ConsumerState<_ProjectRowMenu> createState() => _ProjectRowMenuState();
}

class _ProjectRowMenuState extends ConsumerState<_ProjectRowMenu> {
  /// Which long-running action is in flight, or null. One field rather than two
  /// booleans: publishing and leaving cannot overlap — the menu is replaced by
  /// a spinner while either runs — and two flags would be two chances to leave
  /// one set.
  _ProjectAction? _busy;

  String get _projectId => widget.project.projectId;

  @override
  Widget build(BuildContext context) {
    if (_busy != null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    // `bool?`, and the two `??` defaults below are deliberately opposite ones,
    // carried over from the buttons this replaced: while the linked state is
    // unknown, offer neither publish (which would be wrong on an already-
    // published project) nor leave (which would be wrong on a local one).
    final linked = ref.watch(isProjectLinkedProvider(_projectId)).value;
    final canDelete = widget.isOwner || widget.hasLeft || widget.isSnapshot;
    final notice = widget.deletionNotice;
    final destroyed = notice?.executed ?? false;
    final scheduled = notice != null && !destroyed;

    // Task 11.94/11.101: this trigger is itself labelled only by
    // `tooltip:`. Adopted as the exemption line for every ⋮ overflow trigger
    // in the app: `more_vert` is a universal platform convention, opening it
    // is non-destructive, and every entry inside carries a real label —
    // unlike the bare icons this menu replaced.
    return PopupMenuButton<_ProjectAction>(
      icon: const Icon(Icons.more_vert),
      tooltip: 'Project actions',
      onSelected: _run,
      itemBuilder: (context) => [
        // **Explained, not hidden, for a non-owner (task 11.184).** Every
        // other entry in this menu is shown greyed with its reason when it is
        // not the tapper's to use — this one used to be the exception,
        // removed outright by `if (... && widget.isOwner ...)`. There is no
        // information to protect by hiding it: `linked == false` and
        // `canUseServer` are still real preconditions (there is nothing to
        // publish, or nowhere to publish it), the same "nothing to act on"
        // reasoning the Leave item below uses for `linked == true` — but
        // ownership is a permission, not an absent precondition, and Task
        // 11.12's rule is "explain, don't hide" for exactly that case.
        if (widget.canUseServer && linked == false)
          _item(
            context,
            value: _ProjectAction.publish,
            icon: Icons.cloud_upload_outlined,
            label: 'Publish to server',
            // Task 11.290: a destroyed project's id is retired on the
            // server, and it is unlinked here, which would otherwise offer
            // a publish the server will refuse. Explained, not hidden.
            enabled: widget.isOwner && !destroyed,
            note: destroyed
                ? 'This project was deleted from the server, and its '
                      'identifier cannot be published again.'
                : widget.isOwner
                ? null
                : 'Only a project owner can publish this project.',
          ),
        // **Offered to every member, not only an owner** (task 11.99). This
        // was inside `if (isOwner)`, which is why a contributor or a viewer
        // had nowhere to look up their own role. The screen still re-checks
        // ownership for everything on it that is an action.
        _item(
          context,
          value: _ProjectAction.members,
          icon: Icons.group_outlined,
          label: 'Members',
          note: widget.isOwner
              ? 'Who is on the project, the join code, and who is waiting'
              : 'Who is on the project, and what role you hold',
        ),
        _item(
          context,
          value: _ProjectAction.edit,
          icon: Icons.edit_outlined,
          label: 'Edit project',
        ),
        // Task 11.56. Offered to everybody holding the project, whatever
        // their standing on it: it reads what every role may already read
        // and writes only into a project the person creates and owns — P1,
        // creating a project. Gating it on membership here would be a
        // pre-check stricter than the write (task 11.126's invariant).
        _item(
          context,
          value: _ProjectAction.newSeason,
          icon: Icons.event_repeat_outlined,
          label: 'Start next season',
          note: 'A new project with the same animals, tags and study area',
        ),
        // Task 11.290: **export, reachable from the row**, whenever the
        // project's deletion from the server is scheduled or has happened.
        // That is the moment a member has a deadline on their own records,
        // and the moment the acceptance names. Every other day the export
        // screen is where it always was, under More.
        if (notice != null)
          _item(
            context,
            value: _ProjectAction.export,
            icon: Icons.ios_share_outlined,
            label: 'Export records',
            note: destroyed
                ? 'Save this device\'s copy before deleting it here'
                : 'Save your records before the deletion date',
          ),
        if (linked == true) ...[const PopupMenuDivider(), _leaveItem(context)],
        // Task 11.290. **Delete from the server — the owner's, and only the
        // owner's.** Shown on a published project that is not already gone,
        // greyed with the reason for everybody else, because ownership is a
        // permission and task 11.12's rule is "explain, don't hide".
        if (widget.canUseServer && linked == true && !destroyed) ...[
          const PopupMenuDivider(),
          if (scheduled)
            _item(
              context,
              value: _ProjectAction.cancelDeletion,
              icon: Icons.event_busy_outlined,
              label: 'Cancel scheduled deletion',
              enabled: widget.isOwner,
              note: widget.isOwner
                  ? 'Keeps the project on the server'
                  : 'Only a project owner can cancel it.',
            )
          else
            _item(
              context,
              value: _ProjectAction.scheduleDeletion,
              icon: Icons.delete_forever_outlined,
              label: 'Delete permanently…',
              enabled: widget.isOwner,
              destructive: true,
              note: widget.isOwner
                  ? 'Destroys it for every member, after a countdown'
                  : 'Only a project owner can delete this project '
                        'permanently.',
            ),
        ],
        // **Delete last, below its own divider, in the error colour.** The
        // separation is the point: this and Leave used to be two identical
        // glyphs one tap apart.
        const PopupMenuDivider(),
        _item(
          context,
          value: _ProjectAction.delete,
          icon: Icons.delete_outline,
          label: destroyed ? 'Delete from this device' : 'Move to Trash',
          enabled: canDelete,
          destructive: true,
          note: canDelete
              ? null
              : 'Only a project owner can move this project to the Trash.',
        ),
      ],
    );
  }

  /// Leave, with its verdict resolved where the item is built.
  ///
  /// Never simply absent while the answer is loading, and never absent because
  /// the answer is no: the commonest "no" is *you are this project's last
  /// owner*, which is a real explanation and the one somebody most needs.
  PopupMenuItem<_ProjectAction> _leaveItem(BuildContext context) {
    final verdict = ref.watch(leaveProjectVerdictForProvider(_projectId)).value;
    return _item(
      context,
      value: _ProjectAction.leave,
      icon: Icons.logout,
      label: 'Leave project',
      enabled: verdict?.canLeave == true,
      note: verdict == null
          ? 'Checking…'
          : (verdict.canLeave ? null : verdict.reason),
    );
  }

  /// One menu item: an icon, a label, and — when there is one — a second line
  /// saying what it does or why it is unavailable.
  ///
  /// **Disabled with the reason on the item, not in a tooltip.** Task 11.137
  /// lifted the body of this into [reasonedMenuItem] unchanged, because task
  /// 11.94 found the same defect this shape exists to fix still live in
  /// `log_screen.dart` next door. This method stays as the call shape this
  /// screen already uses; the widget now lives in one place.
  PopupMenuItem<_ProjectAction> _item(
    BuildContext context, {
    required _ProjectAction value,
    required IconData icon,
    required String label,
    String? note,
    bool enabled = true,
    bool destructive = false,
  }) => reasonedMenuItem<_ProjectAction>(
    context,
    value: value,
    icon: icon,
    label: label,
    note: note,
    enabled: enabled,
    destructive: destructive,
  );

  void _run(_ProjectAction action) {
    switch (action) {
      case _ProjectAction.publish:
        _publish();
      case _ProjectAction.members:
        context.push('/more/projects/$_projectId/members');
      case _ProjectAction.edit:
        context.push('/more/project-setup/$_projectId');
      case _ProjectAction.newSeason:
        context.push('/more/projects/$_projectId/new-season');
      case _ProjectAction.export:
        widget.onExport();
      case _ProjectAction.leave:
        _leave();
      case _ProjectAction.scheduleDeletion:
        widget.onScheduleDeletion();
      case _ProjectAction.cancelDeletion:
        widget.onCancelDeletion();
      case _ProjectAction.delete:
        widget.onDelete();
    }
  }

  // ---- Publish (task 10.9) --------------------------------------------------

  Future<void> _publish() async {
    if (!await _confirmPublish()) return;
    if (!mounted) return;
    setState(() => _busy = _ProjectAction.publish);
    try {
      final report = await ref
          .read(projectLinkControllerProvider.notifier)
          .publish(_projectId);
      if (!mounted) return;
      // A publish that the server partly refused is *not* reported as a plain
      // success (task 10.28 / finding D-3). The refused rows are held and
      // listed on the sync status screen, so the confirmation says so and offers
      // the way there rather than leaving "Published" to imply completeness.
      final refused = report.refused.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: refused > 0
              ? const Duration(seconds: 8)
              : const Duration(seconds: 4),
          // Task 11.42: same defect as the undo bars — an action defaults
          // this to `persist: true` (Material 3), which made the 8-second
          // duration above dead whenever there was a "Details" action to
          // show. `refused == 0` never sets `action`, so it was never wrong
          // for the 4-second branch; stated for both so neither can regress
          // silently if that changes.
          persist: false,
          content: Text(switch (report) {
            PublishReport(alreadyLinked: true) =>
              '"${widget.project.projectName}" is already published',
            PublishReport(everythingReachedTheServer: true) =>
              'Published "${widget.project.projectName}"',
            _ =>
              'Published "${widget.project.projectName}", but the server '
                  'would not accept $refused '
                  '${refused == 1 ? 'record' : 'records'}. '
                  '${refused == 1 ? 'It is' : 'They are'} still on this '
                  'device.',
          }),
          action: refused > 0
              ? SnackBarAction(
                  label: 'Details',
                  onPressed: () => context.push('/more/sync-status'),
                )
              : null,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(_failureMessage(e)),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// What to tell somebody whose publish did not finish (task 11.46).
  ///
  /// **This used to be `'Could not publish: $e'`,** and that one interpolation
  /// broke the standing rule twice over ("a check must name what is wrong",
  /// `TriTrack_Technical_Context.md`):
  ///
  /// - For a refusal from the server it printed
  ///   `SyncTransportException(server_rejected)` — a class name, naming
  ///   nothing and suggesting nothing — while
  ///   [SyncTransportException.userMessage], which exists to say the useful
  ///   thing and which the join screen already uses, was never consulted. A
  ///   session that ended mid-publish said "server_rejected" instead of "sign
  ///   in again".
  /// - For a failure *on this device* it printed the exception verbatim, and
  ///   the exceptions reachable here include sqflite's, whose `toString()`
  ///   carries the SQL statement and its bound values. That is a raw database
  ///   error shown to a biologist in a snackbar.
  ///
  /// So nothing is interpolated any more. Each branch is a sentence somebody
  /// can act on, and the last one is deliberately an admission rather than a
  /// guess.
  String _failureMessage(Object error) {
    final name = widget.project.projectName;
    if (error is PublishNotYoursToMake) {
      // Its `toString()` ends with a raw project UUID, which is meaningless on
      // screen. The name is on the row the person just tapped.
      return '"$name" records somebody else as its owner, so it cannot be '
          'published from this account. Nothing has been sent.';
    }
    if (error is SyncTransportException) {
      return error.userMessage ??
          'Could not publish "$name": the server did not accept the upload. '
              'Nothing here has changed; try again.';
    }
    return 'Could not publish "$name" — something on this device went wrong '
        'first. It is still unpublished and nothing has changed. Try again, '
        'and report it if this keeps happening.';
  }

  /// **Task 11.28 part 4: say who is about to own this, before it happens.**
  ///
  /// Publishing is the one action in the app that cannot be undone by anybody,
  /// including whoever it was done to. A project keeps its identifier forever
  /// — it is written into every row — so the server gives the project to
  /// whoever publishes it first, and the real owner is then refused their own
  /// project id permanently. Task 11.24 reproduced that live and Michael
  /// accepted the risk on 2026-08-22 rather than making projects
  /// re-numberable, **conditional on this dialog existing**: the malicious
  /// case needs an attacker who already holds the project, but the likely case
  /// is an accident, and the app actively sets it up — the share screen
  /// suggests emailing a project file to a colleague, and the colleague who
  /// receives it has this action.
  ///
  /// So it does two things, and the second is the one that matters:
  ///
  /// 1. **Names the account that becomes the owner** — the signed-in address,
  ///    not "you", because on a shared field laptop those are different
  ///    questions.
  /// 2. **Says when this project was not created by this account.** The
  ///    project's recorded creator (`Projects.owner_user_id`) is durable and
  ///    survives import, so it is the honest signal for "this came from
  ///    somewhere else" — unlike `origin_device_id`, which any later edit on
  ///    this device overwrites.
  ///
  /// It converts a permanent, silent lockout into a moment of doubt. That is
  /// all it is meant to do; it is a sentence, not a schema change.
  Future<bool> _confirmPublish() async {
    final project = widget.project;
    final session = ref.read(currentSessionProvider).value;
    // Task 11.137: everything this dialog needs is read before it opens, and a
    // read that threw meant no dialog, no message, no publish — the tap simply
    // did nothing. **Nothing has been sent at this point**, which is what the
    // failure sentence has to say, because the one thing somebody must not be
    // left wondering after a failed publish is whether half of it went.
    // `refused: null` — reading your own user row and the project's creator
    // needs no write right, and the publish's own permission check is
    // `_publish`'s, below.
    var imported = false;
    String? creatorName;
    final ready = await runGuardedWrite(
      context,
      write: () async {
        final me = await ref.read(currentUserProvider.future);
        imported = project.ownerUserId != me.userId;
        if (!imported) return;
        final users = await ref.read(userRepositoryProvider.future);
        final creator = await users.findById(
          project.ownerUserId,
          includeDeleted: true,
        );
        final name = [
          creator?.firstName.trim() ?? '',
          creator?.lastName.trim() ?? '',
        ].where((part) => part.isNotEmpty).join(' ');
        creatorName = name.isNotEmpty
            ? name
            : (creator?.email.trim().isNotEmpty ?? false)
            ? creator!.email.trim()
            : null;
      },
      refused: null,
      failed:
          'Could not check who owns "${project.projectName}", so it was not '
          'published and nothing has changed. Try again, and report it if '
          'this keeps happening.',
    );
    if (!ready || !mounted) return false;
    final account = session?.email ?? 'the signed-in account';
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('Publish "${project.projectName}"?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This uploads the project to the server and makes $account '
                  'its owner.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'The server gives a project to whoever publishes it first. '
                  'Nobody else holding a copy can publish it afterwards.',
                ),
                if (imported) ...[
                  const SizedBox(height: 12),
                  Text(
                    creatorName == null
                        ? 'This project was created by somebody else, not by '
                              'this account. Publishing it here locks its real '
                              'owner out of it permanently. Check with them '
                              'first.'
                        : 'This project was created by $creatorName, not by '
                              'this account. Publishing it here locks '
                              '$creatorName out of it permanently. Check with '
                              'them first.',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(dialogContext).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Publish'),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ---- Leave (task 11.28) ---------------------------------------------------

  /// **"Leave this project" (task 11.28).**
  ///
  /// Until this existed, a viewer or a contributor could not get off a project
  /// by any means: there was no control, no route, and membership rows are
  /// owner-only to write. They had to ask an owner, and a device that tried
  /// anyway threw an error no screen caught while the server refused the row
  /// forever — leaving that device permanently out of step. That was M8 in
  /// `CLAUDE_DOCS/PERMISSIONS_MATRIX.md`, the most consequential gap task 11.23
  /// found.
  ///
  /// ## Why the item is only there on a published project
  ///
  /// Not a permission hide — task 11.12's rule (explain, don't hide) is about
  /// controls somebody is *not allowed* to use, and this is a control that has
  /// nothing to act on. A project that is not on a server has no other members
  /// to be a member alongside; its membership rows are local bookkeeping, and
  /// ending your own would change nothing anybody could observe. The item
  /// appears exactly where Publish disappears, so no row gains an action.
  ///
  /// Once the project *is* published the item is always there, disabled with
  /// the reason on it when the answer is no — which for the common case (you
  /// are the project's only owner) is a real explanation rather than an
  /// absence.
  Future<void> _leave() async {
    final project = widget.project;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Leave "${project.projectName}"?'),
        content: const Text(
          // Three sentences, and each answers a question somebody actually
          // asks before tapping this. The middle one is the mirror of the
          // disclosure an owner reads before adding anybody
          // (`removalDisclosure`): removal cannot take data back, and neither
          // does leaving — said here from the other side so nobody believes
          // leaving erases their copy or their contributions.
          // **"a new invitation" became false with task 11.81** — there are
          // no invitations any more. It names both routes back, because they
          // are genuinely different: asking needs the owner to act, and being
          // put back does not.
          'You will stop syncing it. What you recorded stays in the project, '
          'still attributed to you, and your copy here keeps working '
          'offline. Nothing is deleted.\n\n'
          'To come back, ask to join again with the project code, or ask an '
          'owner to put you back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = _ProjectAction.leave);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref
          .read(membershipControllerProvider.notifier)
          .leaveProject(project.projectId);
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            result.serverToldNow
                ? 'You have left "${project.projectName}". It has stopped '
                      'syncing; your copy stays on this device.'
                // Said rather than glossed over: the person is out as far as
                // this device is concerned, but nobody else knows yet, and on
                // a marginal field connection that can be a while.
                : 'You have left "${project.projectName}" on this device. It '
                      'will stop syncing once that reaches the server.',
          ),
        ),
      );
    } on LastOwnerRemoval catch (e) {
      // Reachable despite the disabled item: ownership can change by merge
      // between this list rendering and the confirmation closing.
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on NotAProjectMember catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }
}

enum _DeletedProjectMenuAction { deleteFromServer, cancelDeletion }

enum _TrashedHereMenuAction { deletePermanently }

/// **Trash** — everything this person moved to the Trash, in one place.
///
/// Three kinds of row, in this order (task 11.339 folded the first two in):
///
/// 1. **Moved to the Trash here, not sent to the server yet** (task 11.290,
///    task 11.289's fold-in). A deleted project is hidden from every screen,
///    so until task 11.290 the person who deleted it had no way to learn that
///    the server had refused the deletion — the project they believed gone
///    was live for the team. Two states, said in two sentences: *not sent
///    yet*, the ordinary field condition, which needs nothing from anybody;
///    and *refused*, which does. **Restore** is the same undo it always was
///    — this section was called *Deleted here, not yet on the server* and its
///    button *UNDO* until task 11.339, which changed words and placement
///    only.
/// 2. **Only on this phone** (task 11.339, item 1): moved to the Trash here,
///    and not synced by this phone — never published, or no longer synced
///    here. Restore, and a ⋮ with *Delete permanently…*, which deletes it
///    from this phone (see [ProjectTrash]).
/// 3. **On the server** (task 11.292; moved to the bottom of this screen by
///    task 11.313, "like a Trash folder"; named *Trash* by task 11.324). A
///    project the server still holds as a tombstone, hidden from every
///    member. **Restore, since task 11.302**, brings it back for everybody;
///    the ⋮ schedules its destruction. **No Join**: a tombstoned project is
///    hidden for every member and is not something to join.
class _TrashSection extends StatelessWidget {
  const _TrashSection({
    required this.undelivered,
    required this.trashedHere,
    required this.serverTrash,
    required this.serverFailure,
    required this.restoringProjectId,
    required this.onUndoUndelivered,
    required this.onRestoreHere,
    required this.onDeleteHerePermanently,
    required this.onRestore,
    required this.onDeleteFromServer,
    required this.onCancelDeletion,
  });

  final List<UndeliveredProjectDeletion> undelivered;
  final List<TrashedHere> trashedHere;
  final List<DeletedProjectSummary> serverTrash;
  final Object? serverFailure;
  final String? restoringProjectId;
  final void Function(UndeliveredProjectDeletion) onUndoUndelivered;
  final void Function(TrashedHere) onRestoreHere;
  final void Function(TrashedHere) onDeleteHerePermanently;
  final void Function(DeletedProjectSummary) onRestore;
  final void Function(DeletedProjectSummary) onDeleteFromServer;
  final void Function(DeletedProjectSummary) onCancelDeletion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failure = serverFailure;
    final explanation = [
      'Projects you moved to the Trash. Restore one to bring it back.',
      if (serverTrash.isNotEmpty)
        'One the server still holds stays hidden from every member until you '
            'delete it permanently, and restoring it brings it back for '
            'every member.',
      if (failure != null)
        describeFailure(
          failure,
          fallback:
              'Could not load the projects you deleted that the server still '
              'holds. Try again when you have cell or wifi coverage.',
        ),
    ].join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('Trash', style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(explanation, style: theme.textTheme.bodySmall),
        ),
        for (final deletion in undelivered)
          _UndeliveredRow(
            deletion: deletion,
            onRestore: () => onUndoUndelivered(deletion),
          ),
        for (final project in trashedHere)
          _TrashedHereRow(
            project: project,
            onRestore: () => onRestoreHere(project),
            onDeletePermanently: () => onDeleteHerePermanently(project),
          ),
        for (final project in serverTrash)
          _DeletedOnServerRow(
            project: project,
            restoring: restoringProjectId == project.projectId,
            onRestore: () => onRestore(project),
            onDeleteFromServer: () => onDeleteFromServer(project),
            onCancelDeletion: () => onCancelDeletion(project),
          ),
      ],
    );
  }
}

/// "You moved it to the Trash on …", or without the date when the stored one
/// does not parse.
String _movedToTrashOn(DateTime? at) => at == null
    ? 'You moved it to the Trash.'
    : 'You moved it to the Trash on ${formatDeletionDate(at)}.';

/// A project moved to the Trash here whose deletion the server has not
/// confirmed — see [_TrashSection], kind 1.
class _UndeliveredRow extends StatelessWidget {
  const _UndeliveredRow({required this.deletion, required this.onRestore});

  final UndeliveredProjectDeletion deletion;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        deletion.wasRefused ? Icons.error_outline : Icons.cloud_upload_outlined,
        color: deletion.wasRefused ? scheme.error : null,
      ),
      title: Text(deletion.projectName),
      subtitle: Text(
        deletion.wasRefused
            ? 'The server refused this deletion, so the project is still '
                  'there and syncing for everyone else — it may record '
                  'somebody else as the owner. Restore it here to see it.'
            : '${_movedToTrashOn(deletion.deletedAt)} Not sent to the server '
                  'yet — it goes whenever there is cell or wifi coverage.',
        style: deletion.wasRefused ? TextStyle(color: scheme.onSurface) : null,
      ),
      isThreeLine: true,
      trailing: FilledButton.tonal(
        onPressed: onRestore,
        child: const Text('Restore'),
      ),
    );
  }
}

/// A project moved to the Trash here that this phone does not sync — see
/// [_TrashSection], kind 2. Both controls are unconditional: the list holds
/// only projects this person moved to the Trash, and [ProjectTrash] checks
/// that again inside each write.
class _TrashedHereRow extends StatelessWidget {
  const _TrashedHereRow({
    required this.project,
    required this.onRestore,
    required this.onDeletePermanently,
  });

  final TrashedHere project;
  final VoidCallback onRestore;
  final VoidCallback onDeletePermanently;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(project.projectName),
      subtitle: Text(
        project.everOnServer
            ? '${_movedToTrashOn(project.deletedAt)} This phone no longer '
                  "syncs it, so this is only this phone's copy."
            : '${_movedToTrashOn(project.deletedAt)} It was never published, '
                  'so it is only on this phone.',
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.tonal(
            onPressed: onRestore,
            child: const Text('Restore'),
          ),
          PopupMenuButton<_TrashedHereMenuAction>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Trash actions',
            onSelected: (_) => onDeletePermanently(),
            itemBuilder: (context) => [
              reasonedMenuItem<_TrashedHereMenuAction>(
                context,
                value: _TrashedHereMenuAction.deletePermanently,
                icon: Icons.delete_forever_outlined,
                label: 'Delete permanently…',
                destructive: true,
                note: project.everOnServer
                    ? "Deletes this phone's copy and its records"
                    : 'Deletes it and its records from this phone',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeletedOnServerRow extends StatelessWidget {
  const _DeletedOnServerRow({
    required this.project,
    required this.restoring,
    required this.onRestore,
    required this.onDeleteFromServer,
    required this.onCancelDeletion,
  });

  final DeletedProjectSummary project;
  final bool restoring;
  final VoidCallback onRestore;
  final VoidCallback onDeleteFromServer;
  final VoidCallback onCancelDeletion;

  @override
  Widget build(BuildContext context) {
    final destroyAt = project.destroyAt;
    final scheme = Theme.of(context).colorScheme;
    final deletedOn = project.deletedAt;
    final lines = <String>[
      deletedOn == null
          ? 'You moved it to the Trash. Its records are still held on the '
                'server.'
          : 'You moved it to the Trash on ${formatDeletionDate(deletedOn)}. '
                'Its records are still held on the server.',
      if (destroyAt != null)
        'Scheduled for deletion from the server on '
            '${formatDeletionDate(destroyAt)}. You can cancel it from ⋮.',
    ];
    return ListTile(
      tileColor: destroyAt == null ? null : scheme.errorContainer,
      title: Text(project.projectName),
      subtitle: Text(
        lines.join('\n'),
        style: destroyAt == null
            ? null
            : TextStyle(color: scheme.onErrorContainer),
      ),
      isThreeLine: lines.length > 1,
      // Every row here is the caller's own to restore or destroy — the
      // server lists a project only when it records them as the owner who
      // deleted it, and restores it for exactly the same people (task
      // 11.302) — so both controls are unconditional, unlike the joinable
      // row's menu. Restore is a button rather than a menu item because it
      // is the thing most people arriving here after a mis-tap came for.
      trailing: restoring
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.tonal(
                  onPressed: onRestore,
                  child: const Text('Restore'),
                ),
                PopupMenuButton<_DeletedProjectMenuAction>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: 'Project actions',
                  onSelected: (action) => switch (action) {
                    _DeletedProjectMenuAction.deleteFromServer =>
                      onDeleteFromServer(),
                    _DeletedProjectMenuAction.cancelDeletion =>
                      onCancelDeletion(),
                  },
                  itemBuilder: (context) => [
                    if (destroyAt == null)
                      reasonedMenuItem<_DeletedProjectMenuAction>(
                        context,
                        value: _DeletedProjectMenuAction.deleteFromServer,
                        icon: Icons.delete_forever_outlined,
                        label: 'Delete permanently…',
                        destructive: true,
                        note:
                            'Destroys every record still held on the server, '
                            'after a countdown',
                      )
                    else
                      reasonedMenuItem<_DeletedProjectMenuAction>(
                        context,
                        value: _DeletedProjectMenuAction.cancelDeletion,
                        icon: Icons.event_busy_outlined,
                        label: 'Cancel scheduled deletion',
                        note: 'Keeps the records on the server',
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}

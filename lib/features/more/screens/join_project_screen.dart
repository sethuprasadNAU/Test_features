import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../../core/errors/failure_message.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/join_request_watcher.dart';
import '../../../core/providers/membership_provider.dart';
import '../../../core/providers/project_deletion_provider.dart';
import '../../../core/providers/project_link_provider.dart';
import '../../../data/sync/project_joiner.dart';
import '../../../data/sync/sync_transport.dart';
import '../../../widgets/disabled_reason.dart';
import '../widgets/join_requests_card.dart';
import '../widgets/project_deletion_dialogs.dart';

/// Lists server projects this signed-in user belongs to that this device is
/// not syncing, and joins one on request (task 10.9).
///
/// **"Not syncing", not "has no copy of" (task 11.57).** A project whose local
/// copy has been deleted, or unlinked because this device once learned it was
/// off the project (removed, then readmitted), is one this person is a member
/// of and cannot reach from any other screen — so this is the only route back
/// to it, and it belongs in this list. Joining such a project
/// relinks the copy that is already here rather than downloading a new one over
/// the top of it; the row says so.
///
/// **And since task 11.290 it is the one screen that reaches a project this
/// device does not hold.** The Projects list shows what the phone has; this
/// list shows what the server has. Michael found the gap on 2026-09-20 —
/// seven projects created on a device he no longer owns sat on his server,
/// invisible and undeletable from every device he does own — so an owner can
/// delete a project from the server from its row here, with the same dialogs
/// and the same countdown the Projects list uses, without first downloading
/// a copy they never wanted.
///
/// **Tasks 11.292 and 11.302 once put a second section here: projects the
/// person deleted in the app that the server still holds, with a Restore
/// control.** Task 11.313 moved that whole section to the bottom of
/// [ProjectsScreen] — "nobody looks for a deleted thing on a join screen" —
/// so this screen is only about joining again, the way it was before 11.292.
///
/// Only reachable from [ProjectsScreen] when a server is configured and the
/// user is signed in — the same gate `ProjectLinkController._requireTransport`
/// enforces, so this screen never needs its own "not configured" messaging.
class JoinProjectScreen extends ConsumerStatefulWidget {
  const JoinProjectScreen({super.key});

  @override
  ConsumerState<JoinProjectScreen> createState() => _JoinProjectScreenState();
}

class _JoinProjectScreenState extends ConsumerState<JoinProjectScreen> {
  late Future<_Listing> _available;
  String? _joiningProjectId;

  @override
  void initState() {
    super.initState();
    _available = _load();
    // **Opening this screen is a person asking.** Somebody who navigates here
    // is waiting for an answer, so this reaches the server whatever the
    // device's own bookkeeping thinks, and retries a download that failed
    // earlier rather than waiting for the next app resume.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(joinRequestWatcherProvider.notifier).refresh());
    });
  }

  /// The list, so the screen has one spinner and one reload.
  Future<_Listing> _load() async {
    final controller = ref.read(projectLinkControllerProvider.notifier);
    final joinable = await controller.listAvailableToJoin();
    return _Listing(joinable: joinable);
  }

  /// Re-reads the list. Called when a join code is refused because the person
  /// is **already** on that project (task 11.57): the card's message now points
  /// at this list, and a list loaded before the attempt is the one way that
  /// sentence could still be false on screen.
  ///
  /// **A block body, not an arrow** (task 11.290). It was
  /// `setState(() => _available = _load())`, and an arrow closure returns the
  /// value of its expression — here the `Future` from `_load()` — which
  /// `setState` asserts against in a debug build. In the release build on a
  /// phone the assertion is compiled out and the reload worked, so nothing
  /// ever reported it; the first test to reach this method (through the new
  /// delete-from-server path) met the assertion. The already-a-member path
  /// that has called this since task 11.57 had the same defect and the same
  /// silence.
  void _reload() {
    setState(() {
      _available = _load();
    });
  }

  // ---- Deleting a project this device does not hold (task 11.290) --------

  /// Schedules, or carries out, the destruction of a project listed here —
  /// one this device has no copy of, or a stale one. Same dialogs as the
  /// Projects list, same server, same numbers.
  Future<void> _deleteFromServer({
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
      if (mounted) _reload();
    }
  }

  Future<void> _cancelDeletion({
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
      if (mounted) _reload();
    }
  }

  Future<void> _join(JoinableProject project) async {
    setState(() => _joiningProjectId = project.projectId);
    try {
      final report = await ref
          .read(projectLinkControllerProvider.notifier)
          .join(project.projectId);
      ref.invalidate(allProjectsProvider);
      if (!mounted) return;
      // A join runs an ordinary sync round, push included — this device's own
      // global rows (Users, Tags) go up with it, and the server can refuse one.
      // Held rows are listed on the sync status screen; the confirmation must
      // not imply everything is on the server when it is not (task 10.28).
      final held = report.heldCount;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            report.everythingReachedTheServer
                ? '${project.alreadyOnThisDevice ? 'Restored' : 'Joined'} '
                      '"${project.projectName}"'
                : '${project.alreadyOnThisDevice ? 'Restored' : 'Joined'} '
                      '"${project.projectName}", but the server would not '
                      'accept $held ${held == 1 ? 'record' : 'records'} from '
                      'this device. See Sync Status.',
          ),
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            describeFailure(
              e,
              fallback:
                  'Could not join "${project.projectName}"; nothing has '
                  'changed. Check you are online and try again, and report it '
                  'if this keeps happening.',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _joiningProjectId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join a project')),
      // The code card sits above the list and is always available: someone who
      // was just handed a code has no project on the server yet, so the list
      // below is empty for them and would otherwise be the whole screen.
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: JoinWithCodeCard(onAlreadyAMember: _reload),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: JoinRequestsCard(),
          ),
          const Divider(height: 24),
          FutureBuilder<_Listing>(
            future: _available,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not load projects: ${snapshot.error}'),
                );
              }
              final listing = snapshot.data!;
              final projects = listing.joinable;
              return Column(
                children: [
                  if (projects.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No projects to join. Every project you are on is '
                        'already on this device and syncing.',
                      ),
                    ),
                  for (final project in projects)
                    _JoinableRow(
                      project: project,
                      joining: _joiningProjectId == project.projectId,
                      onJoin: () => _join(project),
                      onDeleteFromServer: () => _deleteFromServer(
                        projectId: project.projectId,
                        name: project.projectName,
                      ),
                      onCancelDeletion: () => _cancelDeletion(
                        projectId: project.projectId,
                        name: project.projectName,
                      ),
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

/// What one load of this screen's list produced.
class _Listing {
  const _Listing({required this.joinable});

  final List<JoinableProject> joinable;
}

/// Ask to join a project with its join code (task 11.81).
///
/// Lives on the join screen because "I was given a code" and "which of my
/// projects is not on this device yet" are the same errand from the user's side
/// — they want a project they do not have. The mechanism differs and the copy
/// says so, and **what the mechanism is changed with task 11.81**: typing a code
/// used to make you a member on the spot. Now it puts you in the owner's list
/// and they decide, so this card must not imply anything has been joined.
class JoinWithCodeCard extends ConsumerStatefulWidget {
  const JoinWithCodeCard({super.key, this.onAlreadyAMember});

  /// Called when the server refuses the code because this person is already on
  /// the project — the one refusal whose remedy is *the list on this screen*,
  /// which therefore has to be current when the sentence appears.
  final VoidCallback? onAlreadyAMember;

  @override
  ConsumerState<JoinWithCodeCard> createState() => _JoinWithCodeCardState();
}

class _JoinWithCodeCardState extends ConsumerState<JoinWithCodeCard> {
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  bool _busy = false;
  bool _prefilled = false;
  String? _error;
  String? _sentToProject;

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  /// Pre-fills the name from this device's own profile, so most people type
  /// nothing.
  ///
  /// It stays **editable**, and the field's label says it is what the owner
  /// will see — because it is caller-supplied text on the one screen where an
  /// owner decides whether to trust somebody, and a pre-filled field that
  /// looked authoritative would imply otherwise.
  void _prefillName(String name) {
    if (_prefilled) return;
    _prefilled = true;
    if (_nameController.text.isEmpty) _nameController.text = name;
  }

  Future<void> _request() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await ref
          .read(membershipControllerProvider.notifier)
          .requestToJoin(
            _codeController.text,
            claimedName: _nameController.text.trim(),
          );
      if (!mounted) return;
      // **Not "Joined".** Nothing has been joined and nothing has been
      // downloaded — the request is in a list somebody else has to look at.
      // Saying "joined" here would be the exact defect task 11.54 exists to
      // have fixed: copy describing a mechanism the code does not have.
      setState(() => _sentToProject = created.projectName);
    } on SyncTransportException catch (e) {
      if (e.reason == joinRefusalAlreadyMember) {
        widget.onAlreadyAMember?.call();
      }
      // Client-authored copy, selected by the server's code — no server text
      // reaches the screen (§4.13). `userMessage` is null for a refusal with no
      // specific remedy, and the fallback says the honest thing.
      setState(
        () => _error =
            e.userMessage ??
            'Could not use that code. Joining a project needs a connection to '
                'the server.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sent = _sentToProject;
    ref.watch(currentUserProvider).whenData((user) {
      final name = [
        user.firstName.trim(),
        user.lastName.trim(),
      ].where((part) => part.isNotEmpty).join(' ');
      if (name.isNotEmpty) _prefillName(name);
    });

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: sent != null
            ? _WaitingForApproval(projectName: sent)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Have a join code?',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  // **The three claims the old copy made are gone, not
                  // softened.** It said codes "expire, can only be used once,
                  // and only work for the email address they were sent to" —
                  // and all three stopped being true with task 11.81.
                  const Text(
                    'Ask a project owner for its join code. The code lets you '
                    'ask to join; the owner decides, and you are told either '
                    'way. This needs a connection.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _codeController,
                    autocorrect: false,
                    enableSuggestions: false,
                    // Upper-cased as they type so what is on screen matches
                    // what is on the whiteboard. `canonicalizeJoinCode` would
                    // accept it either way; this is so the two look the same.
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      letterSpacing: 3,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Join code',
                      hintText: 'ABCD-EFGH',
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _nameController,
                    // Bounded here as well as at the server, so the ordinary
                    // typo is caught by the field rather than by a refusal. The
                    // server is the authority and applies the same rule a
                    // `Users` row's name gets.
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: 'Your name',
                      // Says who reads it and why, because that is what makes
                      // somebody fill it in usefully.
                      helperText:
                          'Shown to the owner so they know who is asking. '
                          'They also see the email address you signed in with.',
                      // No `helperMaxLines` (task 11.332): it was 3, and from
                      // AX1 on a 6.1-inch phone the sentence lost its end to
                      // "…". The theme's limit (`AppTheme.formMessageMaxLines`)
                      // gives it every line it needs.
                    ),
                    onChanged: (_) => setState(() => _error = null),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed:
                        _busy ||
                            canonicalizeJoinCode(_codeController.text) == null
                        ? null
                        : _request,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        // Not "Join" — this asks.
                        : const Text('Ask to join'),
                  ),
                ],
              ),
      ),
    );
  }
}

/// What the person sees once their request is in.
///
/// **This state exists because there is now a gap between asking and joining**,
/// and a screen that returned to a blank code field would leave somebody
/// wondering whether anything had happened at all.
class _WaitingForApproval extends StatelessWidget {
  const _WaitingForApproval({required this.projectName});

  final String projectName;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Waiting for approval',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(
        'Your request to join "$projectName" has been sent. Once the owner '
        'approves it, the project downloads by itself — you do not have to '
        'come back here.',
      ),
      const SizedBox(height: 8),
      Text(
        'If they turn it down, you will see that under "Your requests" '
        'below.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}

/// One project the server holds that this device is not syncing, with the
/// join/restore button — and, for an owner, the way to delete it from the
/// server without first downloading it (task 11.290).
class _JoinableRow extends StatelessWidget {
  const _JoinableRow({
    required this.project,
    required this.joining,
    required this.onJoin,
    required this.onDeleteFromServer,
    required this.onCancelDeletion,
  });

  final JoinableProject project;
  final bool joining;
  final VoidCallback onJoin;
  final VoidCallback onDeleteFromServer;
  final VoidCallback onCancelDeletion;

  @override
  Widget build(BuildContext context) {
    final isOwner = project.project.role == ownerMembershipRole;
    final destroyAt = project.project.destroyAt;
    final scheme = Theme.of(context).colorScheme;
    final lines = <String>[
      // The countdown, for every member, on this list too: a person who
      // deleted their copy still has a deadline if they want it back.
      if (destroyAt != null)
        'Scheduled for deletion from the server on '
            '${formatDeletionDate(destroyAt)}.'
            '${isOwner ? ' You can cancel it from ⋮.' : ''}',
      // **Said rather than left to be feared** (task 11.57). A project
      // already on this device is being *relinked*, not downloaded over the
      // top of what is here.
      if (project.alreadyOnThisDevice)
        'Already on this device but not syncing. Restoring it keeps '
            'everything already here.',
    ];
    return ListTile(
      tileColor: destroyAt == null ? null : scheme.errorContainer,
      title: Text(project.projectName),
      subtitle: lines.isEmpty
          ? null
          : Text(
              lines.join('\n'),
              style: destroyAt == null
                  ? null
                  : TextStyle(color: scheme.onErrorContainer),
            ),
      isThreeLine: lines.isNotEmpty,
      trailing: joining
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: onJoin,
                  child: Text(project.alreadyOnThisDevice ? 'Restore' : 'Join'),
                ),
                // Only an owner gets the menu at all: for anybody else it
                // would hold one greyed item, and a control that can never
                // do anything is clutter rather than an explanation.
                if (isOwner)
                  PopupMenuButton<_JoinableAction>(
                    icon: const Icon(Icons.more_vert),
                    tooltip: 'Project actions',
                    onSelected: (action) => switch (action) {
                      _JoinableAction.deleteFromServer => onDeleteFromServer(),
                      _JoinableAction.cancelDeletion => onCancelDeletion(),
                    },
                    itemBuilder: (context) => [
                      if (destroyAt == null)
                        reasonedMenuItem<_JoinableAction>(
                          context,
                          value: _JoinableAction.deleteFromServer,
                          icon: Icons.delete_forever_outlined,
                          label: 'Delete permanently…',
                          destructive: true,
                          note:
                              'Destroys it for every member, after a '
                              'countdown — no need to download it first',
                        )
                      else
                        reasonedMenuItem<_JoinableAction>(
                          context,
                          value: _JoinableAction.cancelDeletion,
                          icon: Icons.event_busy_outlined,
                          label: 'Cancel scheduled deletion',
                          note: 'Keeps the project on the server',
                        ),
                    ],
                  ),
              ],
            ),
    );
  }
}

enum _JoinableAction { deleteFromServer, cancelDeletion }


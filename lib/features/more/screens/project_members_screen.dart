import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/membership_provider.dart';
import '../../../core/providers/server_transport_provider.dart';
import '../../../core/text/role_labels.dart';
import '../../../data/models/project_membership.dart';
import '../../../data/repositories/project_membership_repository.dart';
import '../../../data/repositories/project_standing.dart';
import '../../../widgets/load_failure.dart';
import '../../../data/sync/sync_transport.dart';

/// The sentence an owner must read before they can let anybody in (task 11.2,
/// moved to its new home by task 11.81).
///
/// **This is a condition of the feature, not copy.** Phase 11's known
/// limitation — "removing a member cannot revoke data already on their device"
/// — was accepted as a tradeoff *conditional on disclosure at the moment
/// somebody is added*, because for a project tracking a poaching-target
/// species, precise historical locations sitting in a departed member's offline
/// copy are a real exposure and the person creating it should know before they
/// do.
///
/// **It used to gate the invite sheet. Its home is now approval** — and
/// re-admission — because approval is the moment an owner actually lets
/// somebody in. Handing out a join code no longer admits anybody, so gating
/// that would be gating the wrong action; nothing should put a person onto a
/// project without the owner having read this at least once.
const String removalDisclosure =
    'Removing someone later stops their syncing, but it cannot delete the '
    'project data already downloaded to their device, exact locations '
    'included. Only let in people you trust with that.';

/// Who is on this project, in what role — and, for an owner, the join code and
/// who is waiting to be let in.
///
/// Deliberately boring. This is the screen someone uses under time pressure —
/// a field tech is standing next to them and needs access now — so every action
/// is one interaction and nothing is hidden behind a menu that has to be
/// discovered.
///
/// ## Every member may open this, not only an owner (task 11.99)
///
/// **This used to be an owner-only screen, and the cost fell on exactly the
/// person least able to absorb it.** The route was rendered on the projects
/// list inside `if (isOwner)`, so a contributor or a viewer had no way to find
/// out what role they held or who else was on the project. The only place the
/// app ever named somebody's own role to them was inside a refusal — *after*
/// they had tried something they were not allowed to do. A field tech whose
/// position estimate would not save could not tell whether that was their role
/// or a fault, and could not see who to ask.
///
/// **The disclosure question, decided rather than defaulted.** Letting a
/// non-owner read this screen shows them colleagues' names, and the reasoning
/// is written up as `TriTrack_Security_Model.md` §4.29. In short: this screen
/// discloses nothing an ordinary member does not already hold. Every member's
/// device is *sent* every other member's `Users` row and `Project_Memberships`
/// row by ordinary sync; the log screen already shows every observer's name to
/// every member and lets them filter by it; and the export screen — which is
/// not role-gated at all — will write every member's `Users` row, email
/// included, into a backup archive for a viewer who asks. Withholding the
/// members screen withheld the information from the *person*, never from the
/// device. What stays owner-only is everything that is an *action*: the join
/// code, the pending-request queue, changing a role, removing somebody, and
/// putting a past member back.
class ProjectMembersScreen extends ConsumerWidget {
  const ProjectMembersScreen({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOwnerAsync = ref.watch(isProjectOwnerProvider(projectId));
    final membershipsAsync = ref.watch(projectMembershipsProvider(projectId));

    return Scaffold(
      appBar: AppBar(title: const Text('Members')),
      body: membershipsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => LoadFailure('who is on this project', error: e),
        data: (memberships) {
          // Rendered only once ownership is known rather than flickering a
          // provisional answer — the pattern task 11.1 established for the
          // other owner-gated screens.
          final isOwner = isOwnerAsync.value;
          if (isOwner == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final current = [
            for (final m in memberships)
              if (m.membership.endDate == null && !m.membership.sync.isDeleted)
                m,
          ];
          final past = [
            for (final m in memberships)
              if (m.membership.endDate != null || m.membership.sync.isDeleted)
                m,
          ];
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              // **First on the screen, above the list** (task 11.99). The
              // question this screen now exists to answer for a non-owner is
              // "what am I allowed to do here", and an answer somebody has to
              // scroll past a member list to reach is one they will not find
              // on the day something was refused.
              _YourRoleCard(projectId: projectId, members: current),
              const _SectionHeader('Current members'),
              // **Said once, in the open, rather than three times in tooltips**
              // (task 11.99). Task 11.12's rule is explain, don't hide — but
              // the explanation on each greyed control lives in a `Tooltip`,
              // and a touchscreen never shows one. This is the same fact where
              // a person on a phone can actually read it.
              //
              // Task 11.138 finished the thought: the remove-member icon's
              // tooltip *replaced its label* with a copy of this sentence when
              // disabled. That copy is gone — the tooltip is the icon's label
              // now, and this line is the only place the reason is stated.
              if (!isOwner)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Only an owner can change a role or remove somebody. You '
                    'can see who is on the project.',
                  ),
                ),
              for (final member in current)
                _MemberTile(member: member, isOwner: isOwner),
              if (isOwner) ...[
                _JoinCodeSection(projectId: projectId),
                _PendingRequestsSection(projectId: projectId),
              ],
              if (past.isNotEmpty) ...[
                const _SectionHeader('Past members'),
                // Kept, and kept visible. A closed stint is the record that
                // somebody collected data on this project between two dates,
                // which is exactly what a permit report or a publication needs
                // — and their observations are still here, attributed to them.
                for (final member in past)
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(member.displayName),
                    subtitle: Text(
                      // `role.label`, not `role.db` (task 11.99): the column
                      // value is a storage spelling, and this line used to be
                      // the app's clearest example of one reaching a screen.
                      '${member.membership.role.label} · '
                      '${_date(member.membership.joinDate)} to '
                      '${member.membership.endDate == null ? 'removed' : _date(member.membership.endDate!)}',
                    ),
                    trailing: isOwner
                        ? _ReadmitButton(
                            projectId: projectId,
                            member: member,
                          )
                        : null,
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ---- Your own role ----------------------------------------------------------

/// **What you are allowed to do here, said before you try** (task 11.99).
///
/// Until this card existed, the only place TriTrack ever named somebody's own
/// role to them was inside a refusal message — *after* they had attempted
/// something the role forbade. A field tech whose position estimate would not
/// save had no way to tell whether that was their role or a fault, and no way
/// to see who to ask. `/w-03` found it while writing the roles page for the
/// user guide, and had to publish a table the app could not show to most of the
/// people it applies to.
///
/// Three things, in the order somebody needs them:
///
/// 1. **The role, spelled as the admission sheet spells it** — *Contributor —
///    records their own*, not the database's `contributor`.
/// 2. **What that permits and what it does not**, because the name alone
///    answers nothing to somebody who has just been refused.
/// 3. **Who to ask.** Named owners, off this project's own membership rows.
///    "Ask an owner" is not actionable on a crew where nobody knows which of
///    four people that is.
///
/// **Null is not an error and must not read as one.** A project on this device
/// legitimately has no membership row for the signed-in person — one created
/// offline and never published, one restored from a backup, one imported from a
/// colleague. `BaseRepository.assertRoleMayWrite` permits in that case and
/// defers to the server, so this card says exactly that rather than implying
/// the person is locked out of their own data.
class _YourRoleCard extends ConsumerWidget {
  const _YourRoleCard({required this.projectId, required this.members});

  final String projectId;

  /// The project's *current* members, already resolved by the screen — so this
  /// card names the owners without opening a second query that could answer at
  /// a different moment than the list beside it.
  final List<ProjectMember> members;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final standingAsync = ref.watch(myProjectStandingProvider(projectId));
    // Rendered only once the answer is known. A card that says "Viewer" for one
    // frame and "Owner" for the next is worse than a card that appears a frame
    // later — this is the sentence somebody is here to read.
    if (!standingAsync.hasValue) return const SizedBox.shrink();
    final standing = standingAsync.requireValue;
    final role = standing.role;
    // Task 11.237: the sentence below for a null role said *"nothing here
    // stops you recording"*. That was true when null meant only *this device
    // cannot say*; it is false for a read-only snapshot of a colleague's
    // project, which is the other thing null used to mean. The card now tells
    // the two apart and says which one this is.
    final snapshot = standing.isSnapshot;
    final theme = Theme.of(context);

    final owners = [
      for (final m in members)
        if (m.membership.role == ProjectRole.owner) m.displayName,
    ]..sort();

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your role', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              snapshot
                  ? 'Not on this project'
                  : role == null
                  ? 'Not recorded on this device'
                  : role.withRights,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              snapshot
                  ? '$snapshotProjectDescription $notAMemberWriteRefusal'
                  : role == null
                  ? 'This device has no membership record for you here — '
                        'normal for a project never published to a server, or '
                        'one that arrived as a file. Nothing here stops you '
                        'recording.'
                  : role.whatYouMayDo,
            ),
            if (role != null && role != ProjectRole.owner) ...[
              const SizedBox(height: 8),
              Text(
                // Named, not "an owner" — on a four-person crew that is the
                // difference between an action and a shrug. Falls back to the
                // generic sentence only when this device genuinely holds no
                // open owner row, which is the same state the creator fallback
                // in `resolveProjectRole` exists to cover.
                owners.isEmpty
                    ? 'Only an owner can change your role.'
                    : owners.length == 1
                    ? 'Ask ${owners.single} to change it.'
                    : 'Ask one of these owners to change it: '
                          '${owners.join(', ')}.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---- The two sections that need a server ------------------------------------

/// **Why a server-only section of this screen has nothing to show**, when the
/// reason is this device rather than the server — task 11.142.
///
/// [subject] completes *"… lives on a server"*: "The join code", "A request to
/// join". [action] completes *"so this section is empty until you ___"*.
///
/// **This exists because the three states were one state.** Both sections below
/// asked the server and rendered the same sentence — *"…so this needs a
/// connection"* — for a device with no server address, a device signed out, and
/// a server that did not answer. For the first of those the sentence names the
/// wrong cause: **a device with no server is this app's default and fully
/// supported state**, it is what somebody sees the first time they open the
/// app, and there is nothing wrong with their connection. The `error:` branch
/// of each section now means only the third — *the server did not answer* —
/// which is the one thing it was always supposed to mean.
String noServerSectionText(NoServerReason reason, {required String subject}) =>
    switch (reason) {
      // Not phrased as a failure, because it is not one.
      NoServerReason.noAddress =>
        '$subject lives on a server, and this device is not using one. To '
            'share this project, set one up in More → Server Connection.',
      NoServerReason.notSignedIn =>
        '$subject lives on a server. Sign in from More → Server Connection '
            'to see it.',
      // Deliberately does not say which part of the address is wrong: that
      // sentence is `ServerUrlProblem.message` and it belongs beside the field
      // that holds the address. Saying it twice is how the two drift.
      NoServerReason.addressRefused =>
        '$subject lives on a server, and this device will not use the '
            'address it has saved. It is not your network or the server: open '
            'More → Server Connection to see what to change.',
    };

// ---- The join code ----------------------------------------------------------

/// The project's join code, whether joining is on, and the team-size limit.
///
/// **Replaces the Invitations section** (task 11.81). That section listed one
/// code per person; this one shows the single code the whole crew uses. Needs
/// the server, and says so when it cannot reach one rather than rendering an
/// empty state that reads as "there is no code".
class _JoinCodeSection extends ConsumerWidget {
  const _JoinCodeSection({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final noServer = ref.watch(noServerReasonProvider);
    final settingsAsync = ref.watch(projectJoinSettingsProvider(projectId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Join code'),
        // Asked before the server is: when this device cannot make a request
        // at all, the answer is about this device and not about the server,
        // and the two must not be flattened into one sentence.
        //
        // **Only when there is nothing to show.** This explains an empty
        // section; a section with an answer in it needs no explaining, and a
        // guard that hid real data behind a sentence about the device would be
        // strictly worse than the spinner it replaced.
        if (noServer.value case final reason? when !settingsAsync.hasValue)
          _SectionNote(noServerSectionText(reason, subject: 'The join code'))
        else
          settingsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
            // Reached only with a server this device could have asked, so it
            // means what it says: the request went out and did not come back.
            error: (_, _) => const _SectionNote(
              'The join code is kept on the server, and the server did not '
              'answer. Open this screen again to try once more.',
            ),
            data: (settings) => _JoinCodeBody(
              projectId: projectId,
              settings: settings,
            ),
          ),
      ],
    );
  }
}

class _JoinCodeBody extends ConsumerStatefulWidget {
  const _JoinCodeBody({required this.projectId, required this.settings});
  final String projectId;
  final JoinSettings settings;

  @override
  ConsumerState<_JoinCodeBody> createState() => _JoinCodeBodyState();
}

class _JoinCodeBodyState extends ConsumerState<_JoinCodeBody> {
  bool _busy = false;
  String? _error;

  JoinSettings get settings => widget.settings;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      setState(
        () => _error =
            'Could not change the join code. This part of TriTrack needs a '
            'connection to the server.',
      );
      assert(() {
        debugPrint('join settings change failed: $e');
        return true;
      }());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = settings.code;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          value: settings.joiningEnabled,
          onChanged: _busy
              ? null
              : (value) => _run(
                  () => ref
                      .read(membershipControllerProvider.notifier)
                      .updateJoinSettings(
                        projectId: widget.projectId,
                        joiningEnabled: value,
                      ),
                ),
          title: const Text('Let people join with a code'),
          // **Says what switching it off does and does not do.** Turning
          // joining off is not a way to clear the queue, and describing it as
          // one would leave an owner believing they had dismissed people they
          // had not.
          subtitle: Text(
            settings.joiningEnabled
                ? 'Anyone with the code can ask to join. You decide who '
                      'actually gets in.'
                : 'Nobody can ask to join. Anyone already waiting stays in the '
                      'list below and you can still approve them.',
          ),
        ),
        if (settings.joiningEnabled && code != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  formatJoinCode(code),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Share it any way you like. It does not expire, and the '
                  'same code works for everybody.',
                ),
                const SizedBox(height: 4),
                // **Said plainly, because it is the thing that changed.**
                // Holding the code is not the same as being on the project any
                // more, and an owner who does not know that will treat a leak
                // as a disaster or, worse, treat it as harmless in the other
                // direction and hand out an *approval*.
                Text(
                  'Having the code only lets someone ask. Nobody joins until '
                  'you approve them below.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: formatJoinCode(code)),
                        ),
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _rotate,
                        icon: const Icon(Icons.autorenew),
                        label: const Text('New code'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        ListTile(
          title: const Text('Team size limit'),
          // **The pending count is shown next to the member count, not summed
          // into one number.** They both count toward the limit, and an owner
          // reading "48 of 50" with no breakdown cannot make sense of a "team
          // is full" refusal when only 40 people are on the project.
          subtitle: Text(
            '${settings.memberCount} '
            '${settings.memberCount == 1 ? 'member' : 'members'}'
            '${settings.pendingCount > 0 ? ' and ${settings.pendingCount} waiting' : ''}'
            ', out of ${settings.teamSizeLimit}. '
            'People waiting for approval take up a place too.',
          ),
          isThreeLine: true,
          trailing: DropdownButton<int>(
            value: _limitOptions.contains(settings.teamSizeLimit)
                ? settings.teamSizeLimit
                : null,
            hint: Text('${settings.teamSizeLimit}'),
            underline: const SizedBox.shrink(),
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null) return;
                    _run(
                      () => ref
                          .read(membershipControllerProvider.notifier)
                          .updateJoinSettings(
                            projectId: widget.projectId,
                            teamSizeLimit: value,
                          ),
                    );
                  },
            items: [
              for (final option in _limitOptions)
                DropdownMenuItem(value: option, child: Text('$option')),
            ],
          ),
        ),
        // **Lowering the limit below the current head count is allowed, and is
        // said plainly rather than rendered as an error.** Nobody is removed;
        // new requests are refused.
        if (settings.memberCount + settings.pendingCount >
            settings.teamSizeLimit)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'The limit is below the number of people on this project. Nobody '
              'is removed, but new requests are refused until there is room.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  /// Rotation, with the one bulk operation in the whole design behind it.
  ///
  /// **"Also clear the people waiting" is offered here and nowhere else, and
  /// it starts unticked.** There is deliberately no bulk reject on the pending
  /// list: an accidental "reject all" forces every legitimate requester to ask
  /// again and be contacted individually, and that accident is far likelier
  /// than the flood it would defend against. Behind a rotation an owner went
  /// looking for, the same operation cannot be reached by mis-tapping a list.
  Future<void> _rotate() async {
    var clearPending = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Make a new join code?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The old code stops working at once. Anyone you gave it to '
                'will need the new one.',
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: clearPending,
                onChanged: (value) =>
                    setDialogState(() => clearPending = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('Also clear everyone waiting'),
                subtitle: const Text(
                  'They will be told their request is gone and can ask again '
                  'with the new code. Leave this off to keep them.',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('New code'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    await _run(
      () => ref
          .read(membershipControllerProvider.notifier)
          .rotateJoinCode(
            projectId: widget.projectId,
            clearPending: clearPending,
          ),
    );
  }
}

/// The limits an owner can pick from.
///
/// A fixed list rather than a free number field: the value is a judgement about
/// crew size, not a measurement, and a text field invites the typo that locks
/// everybody out.
const List<int> _limitOptions = [5, 10, 25, 50, 100, 250];

// ---- Pending requests -------------------------------------------------------

/// The people waiting for this owner to decide.
///
/// **This is the screen the whole design turns on.** It is the one place in
/// TriTrack where somebody decides whether to trust a person by reading a
/// string, which is why the email and the name are presented differently — see
/// [_RequestTile].
class _PendingRequestsSection extends ConsumerWidget {
  const _PendingRequestsSection({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final noServer = ref.watch(noServerReasonProvider);
    final requestsAsync = ref.watch(projectJoinRequestsProvider(projectId));
    if (noServer.value case final reason? when !requestsAsync.hasValue) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeader('Waiting to join'),
          _SectionNote(
            noServerSectionText(reason, subject: 'A request to join'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader('Waiting to join'),
        requestsAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => const _SectionNote(
            'Requests to join are kept on the server, and the server did not '
            'answer. Open this screen again to try once more.',
          ),
          data: (requests) {
            final pending = [
              for (final r in requests)
                if (r.isPending) r,
            ];
            if (pending.isEmpty) {
              return const _SectionNote('Nobody is waiting.');
            }
            return Column(
              children: [
                for (final request in pending)
                  _RequestTile(projectId: projectId, request: request),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// One person waiting, and the two things an owner knows about them.
///
/// **The email and the name are not equally trustworthy and this tile must not
/// present them as if they were** (Michael's decision 1, 2026-08-31).
///
/// - The **email** is what the *server* authenticated — the address this person
///   proved they can read in order to sign in. It is the identifier, it is
///   shown as the title, and it is the thing an owner should decide on if the
///   two ever disagree.
/// - The **name** is what the requester *says* they are called. It is
///   pre-filled from their own profile, so most people type nothing, but it is
///   still caller-supplied and this tile labels it as a claim.
///
/// **Michael overruled the recommendation to carry no name at all, and his
/// reason is the better one:** an owner may simply not recognise
/// `f.lastname@nau.edu`, and a name is what turns approval into a judgement
/// rather than a guess. The cost is that a stranger chooses a string this screen
/// renders — which is why the server bounds it exactly as it bounds a `Users`
/// row's name, refusing control characters and bidirectional-override
/// characters that would make one person's name render as another's.
///
/// **A missing name renders as absent, never as a placeholder** somebody could
/// mistake for a name that was typed.
class _RequestTile extends ConsumerWidget {
  const _RequestTile({required this.projectId, required this.request});

  final String projectId;
  final JoinRequestSummary request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final claimed = request.claimedName?.trim() ?? '';
    return ListTile(
      isThreeLine: true,
      leading: const Icon(Icons.pending_outlined),
      // The authenticated address is the title, because it is the fact.
      title: Text(request.email),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (claimed.isEmpty)
            Text(
              'No name given',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            // "Says they are" rather than a bare name, so the claim is legible
            // as a claim without a second line of explanation on every row.
            Text('Says they are $claimed'),
          Text(
            'Asked ${_date(DateTime.parse(request.requestedAt))}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => _reject(context, ref),
            child: const Text('Reject'),
          ),
          FilledButton(
            onPressed: () => _approve(context, ref),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
  }

  Future<void> _approve(BuildContext context, WidgetRef ref) async {
    final role = await showAdmissionSheet(
      context,
      title: 'Let ${request.email} in?',
      // Contributor unless changed — the ordinary case is a field tech who
      // records their own observations.
      initialRole: ProjectRole.contributor,
      actionLabel: 'Approve',
    );
    if (role == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(membershipControllerProvider.notifier)
          .approveJoinRequest(
            projectId: projectId,
            requestId: request.requestId,
            role: role,
          );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            // Client-authored copy selected by the server's refusal code — no
            // server text ever reaches the screen (§4.13).
            (e is SyncTransportException ? e.userMessage : null) ??
                'Could not approve that request. This needs a connection to '
                    'the server.',
          ),
        ),
      );
    }
  }

  /// **One at a time, and there is deliberately no "reject all".**
  ///
  /// An accidental bulk reject forces every legitimate requester to ask again
  /// and be contacted individually, and that accident is far likelier than the
  /// flood a bulk control would defend against. The more probable failure wins.
  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reject this request?'),
        content: Text(
          '${request.email} will be told their request was turned down. They '
          'can ask again with the same code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(membershipControllerProvider.notifier)
          .rejectJoinRequest(
            projectId: projectId,
            requestId: request.requestId,
          );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Could not reject that request. This needs a connection to the '
            'server.',
          ),
        ),
      );
    }
  }
}

/// The sheet that gates every admission: pick a role, read the disclosure,
/// then act.
///
/// **This is where the removal disclosure lives now** (task 11.81). It used to
/// gate the invite sheet, because issuing an invitation was how somebody got
/// onto a project. Under the join code, handing out the code admits nobody —
/// approval does — so gating the code would gate the wrong action. Both
/// approval and re-admission come through here, which is what makes "nothing
/// puts a person onto a project without the owner having read this" true rather
/// than nearly true.
///
/// Returns the chosen role, or null if the owner backed out.
Future<ProjectRole?> showAdmissionSheet(
  BuildContext context, {
  required String title,
  required ProjectRole initialRole,
  required String actionLabel,
  String? note,
}) {
  return showModalBottomSheet<ProjectRole>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: _AdmissionSheet(
        title: title,
        initialRole: initialRole,
        actionLabel: actionLabel,
        note: note,
      ),
    ),
  );
}

class _AdmissionSheet extends StatefulWidget {
  const _AdmissionSheet({
    required this.title,
    required this.initialRole,
    required this.actionLabel,
    this.note,
  });

  final String title;
  final ProjectRole initialRole;
  final String actionLabel;
  final String? note;

  @override
  State<_AdmissionSheet> createState() => _AdmissionSheetState();
}

class _AdmissionSheetState extends State<_AdmissionSheet> {
  late ProjectRole _role = widget.initialRole;
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    // Scrollable: on a phone in landscape, or with the keyboard up, this sheet
    // is taller than what is left of the screen — and a disclosure that has
    // scrolled off the bottom of a clipped Column is not a disclosure.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
          if (widget.note != null) ...[
            const SizedBox(height: 8),
            Text(
              widget.note!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          DropdownButtonFormField<ProjectRole>(
            initialValue: _role,
            decoration: const InputDecoration(labelText: 'Role'),
            // The role gradient spelled out, because "contributor" alone does
            // not tell an owner what it permits. `isExpanded` so a long label
            // ellipsizes instead of overflowing the sheet on a narrow phone.
            //
            // **The three strings moved to `role_labels.dart`** (task 11.99)
            // and did not change a character: this sheet's wording is the one
            // a person meets at the moment they are let in, so it is the
            // wording every other surface now draws from rather than the other
            // way round.
            isExpanded: true,
            items: [
              for (final role in rolesLeastPermissiveFirst)
                DropdownMenuItem(value: role, child: Text(role.withRights)),
            ],
            onChanged: (role) =>
                setState(() => _role = role ?? ProjectRole.contributor),
          ),
          const SizedBox(height: 20),
          // The disclosure. Not a footnote, not a link — the control.
          CheckboxListTile(
            value: _acknowledged,
            onChanged: (value) =>
                setState(() => _acknowledged = value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text(removalDisclosure),
            subtitle: const Text('I understand.'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _acknowledged
                ? () => Navigator.of(context).pop(_role)
                : null,
            child: Text(widget.actionLabel),
          ),
        ],
      ),
    );
  }
}

// ---- Past members -----------------------------------------------------------

/// **Put a past member back on the project, directly** (task 11.55, re-shaped
/// by 11.81).
///
/// A returning field technician is the normal case rather than an edge one —
/// the same person on next season's crew, or somebody who left mid-season and
/// came back.
///
/// **What changed, and it is an improvement worth stating.** Before this, an
/// owner looking straight at a departed member's row had to open an invite
/// sheet, retype an address that was on the screen in front of them, and then
/// wait for that person to go and redeem a code. Now the owner puts them back
/// with one tap and their next sync picks it up. No code, no request, no round
/// trip, for somebody the owner already trusts and already removed themselves.
///
/// **The bound that makes it safe comes from the project's own history**, not
/// from this button: the server refuses anyone who does not already hold a
/// closed membership row here and no open one. So it discloses nothing the
/// owner cannot already read off this very screen, grants nothing new, and
/// cannot add a stranger.
///
/// It is never silent — it goes through [showAdmissionSheet] like an approval
/// does, so the role is a choice and the removal disclosure is read.
class _ReadmitButton extends ConsumerWidget {
  const _ReadmitButton({required this.projectId, required this.member});

  final String projectId;
  final ProjectMember member;

  // Task 11.94/11.101: this and the remove-member icon below are labelled
  // only by `tooltip:`. Task 11.99 already made and wrote down this call for
  // both — alone at the end of its row rather than beside a destructive
  // twin, and each confirms before acting (this one through
  // `showAdmissionSheet`, the same weight as an approval). Adopted rather
  // than overruled.
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Tooltip(
      message: 'Put ${member.displayName} back on this project',
      child: IconButton(
        icon: const Icon(Icons.person_add_alt_1),
        onPressed: () => _readmit(context, ref),
      ),
    );
  }

  Future<void> _readmit(BuildContext context, WidgetRef ref) async {
    final role = await showAdmissionSheet(
      context,
      title: 'Put ${member.displayName} back?',
      // The role they last held, shown and changeable before acting — a
      // returning member is often returning to a different job, and reusing it
      // silently would be a decision made on the owner's behalf.
      initialRole: member.membership.role,
      actionLabel: 'Put them back',
      note:
          'They go back on straight away — they do not need a code or have to '
          'ask. Their earlier time on the project stays on the record.',
    );
    if (role == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(membershipControllerProvider.notifier)
          .readmitMember(
            projectId: projectId,
            userId: member.membership.userId,
            role: role,
          );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            (e is SyncTransportException ? e.userMessage : null) ??
                'Could not put them back. This needs a connection to the '
                    'server.',
          ),
        ),
      );
    }
  }
}

// ---- Existing members -------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// A sentence under a section header, where a list would otherwise be.
///
/// **Every section on this screen that can be empty says why it is empty**
/// (task 11.142), and they say it in the same place with the same indent, so a
/// reader can tell "there is nothing here" from "this has not loaded yet"
/// without looking for a spinner.
class _SectionNote extends StatelessWidget {
  const _SectionNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(text),
  );
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({required this.member, required this.isOwner});

  final ProjectMember member;
  final bool isOwner;

  ProjectMembership get membership => member.membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.person_outline),
      title: Text(member.displayName),
      subtitle: Text('Joined ${_date(membership.joinDate)}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // One interaction to change a role, per the plan. A dropdown showing
          // the current value beats a menu that hides it.
          // **Closed it reads `Contributor`; open, each choice reads
          // `Contributor — records their own`** (task 11.99).
          //
          // This control printed `role.db` — the value stored in the database
          // column — so the members screen and the admission sheet spelled the
          // same three roles two different ways, one screen apart. It cost the
          // user guide a sentence explaining they are the same roles.
          //
          // `selectedItemBuilder` is what lets both be true at once: the button
          // sits in a trailing `Row` with no width to spare, while the menu it
          // opens is full-width and can afford to say what each role permits at
          // the moment somebody is choosing between them.
          DropdownButton<ProjectRole>(
            value: membership.role,
            underline: const SizedBox.shrink(),
            // **`itemHeight: null`** (the fix task 11.232 already used for
            // `tag_form.dart`'s project dropdown): `DropdownButton` boxes its
            // closed display at a fixed `itemHeight` (48px by default) unless
            // told not to, and that box does not grow with text scale. At
            // AX3 "Contributor" needs more than 48px and was clipped to 86%
            // shown with no stripe. `itemHeight: null` sizes the box to each
            // item's own content instead.
            itemHeight: null,
            onChanged: isOwner
                ? (role) {
                    if (role != null && role != membership.role) {
                      _changeRole(context, ref, role);
                    }
                  }
                : null,
            selectedItemBuilder: (context) => [
              for (final role in rolesLeastPermissiveFirst)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(role.label),
                ),
            ],
            items: [
              for (final role in rolesLeastPermissiveFirst)
                DropdownMenuItem(value: role, child: Text(role.withRights)),
            ],
          ),
          // Task 11.138: this tooltip swapped its *label* for a *reason* when
          // disabled — so on a phone neither was readable, and on a pointer
          // the label disappeared exactly when the icon was hardest to guess.
          // It is the label again, always. The reason is already in the open
          // above the member list (task 11.99's line, a few rows up in this
          // file): "Only an owner can change a role or remove somebody." Said
          // once, where a phone can read it, rather than once per member in a
          // tooltip a phone cannot open.
          Tooltip(
            message: 'Remove from project',
            child: IconButton(
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: isOwner ? () => _remove(context, ref) : null,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _changeRole(
    BuildContext context,
    WidgetRef ref,
    ProjectRole role,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(membershipControllerProvider.notifier)
          .changeRole(membership, role);
    } on LastOwnerRemoval catch (e) {
      // A user-facing error with an explanation, unlike UnauthorizedMutation —
      // the person hitting it is an owner doing something they are entitled to
      // do, in a project where it happens to be the last thing holding
      // management together (task 11.1).
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove from project?'),
        // The same disclosure as the admission flow, at the other end of the
        // lifecycle — because this is the moment somebody is most likely to
        // believe removal took the data back.
        content: const Text(removalDisclosure),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(membershipControllerProvider.notifier)
          .endMembership(membership);
    } on LastOwnerRemoval catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// `YYYY-MM-DD` in this device's zone (task 11.326). Every value printed
/// here is an instant — a join, a departure, a request — decoded as UTC, and
/// its UTC day is a day out for an evening in Arizona or a morning in New
/// Zealand. The Delete-project dialogs already read their dates this way.
String _date(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

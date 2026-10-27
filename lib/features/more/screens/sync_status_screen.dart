import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failure_message.dart';
import '../../../core/providers/active_selection_provider.dart';
import '../../../core/providers/project_deletion_provider.dart';
import '../../../core/providers/sync_conflicts_provider.dart';
import '../../../core/providers/sync_dropped_rows_provider.dart';
import '../../../core/providers/sync_held_rows_provider.dart';
import '../../../core/providers/sync_provider.dart';
import '../../../data/sync/dropped_row_details.dart';
import '../../../data/sync/consent_summary.dart';
import '../../../data/sync/held_row_details.dart';
import '../../../data/sync/sync_conflicts.dart';
import '../../../data/sync/sync_dropped_rows.dart';
import '../../../data/sync/sync_transport.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/sync_status_presentation.dart';
import '../../../data/sync/sync_schedule.dart';

/// What a person is told when "Try again" cannot finish (task 11.236). The
/// row's release already happened by the time this could be shown — nothing
/// is lost — but the sentence does not claim to know that the retry itself
/// failed for a recoverable reason, only that it did not finish and that the
/// row is still being tracked.
const String kHeldRowRetryFailedMessage =
    'Could not retry that record. It will be offered again on the next '
    'sync. Try again, and report it if this keeps happening.';

/// Full detail behind the sync status icon (task 10.12): the current state in
/// plain language, and the reviewable list of "an edit you made was
/// superseded" that last-write-wins can produce silently otherwise.
///
/// **This is the tap-through, and after task 11.189 it is the only place the
/// whole story is written.** A colour on a 28-pixel icon is a summary; every
/// sentence that used to be on the strip above every tab is here, along with
/// the "Dismiss until tomorrow morning" control that strip carried.
///
/// Reached from the More menu entry — which [MoreScreen] hides entirely when
/// no server is configured — and from the status icon, which is absent in the
/// same state for the same reason. So this screen does not need to re-check
/// task 10.2's invariant: nothing links here when nothing has ever tried to
/// sync.
class SyncStatusScreen extends ConsumerWidget {
  const SyncStatusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectId = ref.watch(activeProjectIdProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync Status')),
      body: projectId == null
          ? const _NoActiveProject()
          : _Body(projectId: projectId),
    );
  }
}

/// **What this screen says with no project open** (task 11.313) — most often
/// because none has been created yet, but also the state right after
/// deleting the open one, which used to read as a dead end: *Sync now* is
/// gone along with everything else on this screen, and nothing said whether
/// the deletion itself had gone anywhere.
///
/// **It has, on its own, without this screen's help.** Deleting the open
/// project makes an immediate delivery attempt
/// (`ProjectsScreen._offerStrandedProjectChanges`), and whether or not that
/// attempt has signal, `SyncController.deliverPendingProjectChanges` runs
/// again on every foreground and on every ordinary *Sync now* elsewhere in
/// the app (`app.dart`'s `_syncOnForeground`, ahead of the open project's own
/// round) until the server has taken it — there is no path that clears the
/// pending state without delivering it, and no give-up case short of the
/// project already being destroyed on the server. So the guarantee is real,
/// and this sentence says so instead of a screen that looks like it dropped
/// the deletion along with the button.
///
/// [undeliveredProjectDeletionsProvider] is the same derivation the Projects
/// list's Trash reads for its "not sent to the server yet" rows (task 11.339
/// folded the old "Deleted here, not yet on the server" section in) — asked
/// here too, because a person who came looking for a stuck deletion should
/// not have to be told to go elsewhere for the one case where there
/// genuinely is something to watch.
class _NoActiveProject extends ConsumerWidget {
  const _NoActiveProject();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final undelivered =
        ref.watch(undeliveredProjectDeletionsProvider).value ?? const [];
    final count = undelivered.length;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('No project is selected.', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              count == 0
                  ? 'If you just deleted the open project, that has already '
                        'reached the server, or will the next time this '
                        'device has cell or wifi coverage.'
                  : '$count ${count == 1 ? 'deletion is' : 'deletions are'} '
                        'still waiting to reach the server, and will go when '
                        'this device has cell or wifi coverage. To undo, '
                        'restore it from Projects → Trash.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(syncControllerProvider);
    final conflictsAsync = ref.watch(syncConflictEventsProvider(projectId));
    final heldAsync = ref.watch(syncHeldRowDetailsProvider(projectId));
    final droppedAsync = ref.watch(syncDroppedRowsProvider(projectId));

    return RefreshIndicator(
      onRefresh: () => ref.read(syncControllerProvider.notifier).syncNow(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          statusAsync.when(
            data: (status) => _StatusCard(status: status),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) =>
                LoadFailure('the sync status', error: e, centered: false),
          ),
          // Above "Overwritten edits", deliberately: an overwritten edit is a
          // record whose *older version* was discarded, and the server holds a
          // newer one. A refused record is not on the server at all.
          heldAsync.when(
            data: (held) => held.isEmpty
                ? const SizedBox.shrink()
                : _HeldRowsSection(projectId: projectId, held: held),
            loading: () => const SizedBox.shrink(),
            error: (e, _) => LoadFailure(
              'the records the server would not accept',
              error: e,
              centered: false,
            ),
          ),
          // Also above "Overwritten edits", for the mirror-image reason: this
          // is a record the server sent that never made it into this device's
          // database at all, not an older version being replaced.
          droppedAsync.when(
            data: (dropped) => dropped.isEmpty
                ? const SizedBox.shrink()
                : _DroppedRowsSection(dropped: dropped),
            loading: () => const SizedBox.shrink(),
            error: (e, _) => LoadFailure(
              'the records that did not arrive on this device',
              error: e,
              centered: false,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Overwritten edits',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'When two devices edit the same record, the newer edit wins. '
            'Edits replaced on this device are listed here.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          conflictsAsync.when(
            data: (events) => events.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No overwritten edits.'),
                  )
                : Column(
                    children: [
                      for (final event in events)
                        ConflictEventCard(projectId: projectId, event: event),
                    ],
                  ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) =>
                LoadFailure('the overwritten edits', error: e, centered: false),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends ConsumerWidget {
  const _StatusCard({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presentation = SyncStatusPresentation.of(status);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // **The icon and its colour come from the same place the status
            // icon on the map reads** (task 11.189). Until then this card
            // carried its own exhaustive switch over the thirteen health
            // states beside the bar's — they agreed on twelve and disagreed
            // on `healthy`, grey on the bar and green here, and nothing
            // would ever have said so. The headline below stays this
            // screen's own: it is a title, and the shared string is a
            // sentence.
            Row(
              children: [
                Icon(presentation.icon, color: presentation.color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _headline(),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(_lastSyncedLine()),
            // **The tense, in full, on the screen with room for it** (task
            // 11.116). The bar one tap up appends a short clause that a phone
            // can truncate; this is where the whole of it is said, including
            // the sentence that separates the two things a person needs to
            // tell apart before deciding whether to walk somewhere with
            // signal.
            if (_notRetriedLine() case final line?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  line,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (status.pendingCount > 0)
              Text(
                '${status.pendingCount} '
                '${status.pendingCount == 1 ? 'record' : 'records'} not yet '
                'sent to the server.'
                // **The same silence the sync bar refuses to keep**
                // (task 11.59). "Not yet sent" reads as *about to be*, and
                // under "Only when I ask" nothing is going to send it until
                // somebody presses the button directly below this line.
                '${status.schedule.automaticEnabled ? '' : ' Sync is set to '
                          '"${SyncFrequency.onlyWhenIAsk.label}", so '
                          '${status.pendingCount == 1 ? 'it stays' : 'they stay'} '
                          'here until you tap Sync now.'}',
              ),
            // Stated on the status card as well as in the section below, because
            // "last successful sync: 2 min ago" is otherwise the only line a
            // glance takes in, and on its own it is misleading while a record
            // is being held (task 10.28 / finding D-3).
            if (status.heldCount > 0)
              Text(
                '${status.heldCount} '
                '${status.heldCount == 1 ? 'record is' : 'records are'} '
                'safe on this device but not yet on the server. Tap below '
                'for why.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            // The inbound counterpart, and it is a different sentence from the
            // one above on purpose: a held record is on this device and
            // nowhere else, and one of these is everywhere *except* this
            // device. Confusing the two would send somebody hunting for data
            // loss that has not happened.
            if (status.droppedOnArrivalCount > 0)
              Text(
                '${status.droppedOnArrivalCount} '
                '${status.droppedOnArrivalCount == 1 ? 'record' : 'records'} '
                'the server sent could not be read by this app. Nothing has '
                'been lost — update this app, and '
                '${status.droppedOnArrivalCount == 1 ? 'it arrives' : 'they arrive'} '
                'the next time '
                '${status.droppedOnArrivalCount == 1 ? 'it changes' : 'they change'}. '
                'See below for which and why.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ...?_advice(context, status),
            if (status.hasUnrecognizedFields) ...[
              const SizedBox(height: 8),
              const Text(
                'Update this app to see every field: some that other devices '
                'recorded are kept safe here but not shown.',
              ),
            ],
            // Task 11.58. Not a warning — the round that found it went on to
            // sync — so it is not in the error color and is not a health
            // state. It is the answer to "why did my phone just fetch the
            // whole project again" and "why did the waiting count jump", and
            // without it both look like a fault.
            if (_databaseChangedLine() case final line?) ...[
              const SizedBox(height: 8),
              Text(line, key: const ValueKey('server_database_changed')),
            ],
            // **The dismiss control's home after task 11.189.**
            //
            // It was a close button on the sync bar (task 11.114), on exactly
            // these two states and no others — a held record, a rejected
            // certificate or an ended membership has never had anything here
            // for a dismiss to silence, because none of them goes away by
            // being ignored. The bar is gone; the criterion is not, and this
            // is the screen the icon that replaced it taps through to.
            //
            // It also gained a sentence it never had room for: a 12-point
            // strip could only carry "Dismiss until tomorrow morning" as a
            // tooltip a touchscreen never shows (task 11.94/11.101), which is
            // why the SnackBar below exists at all. Here the button says it
            // in full, and the SnackBar stays because the confirmation is
            // still worth having at the moment somebody acts.
            if (status.health == SyncHealth.staleRecordsPending ||
                status.health == SyncHealth.staleNothingPending) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('dismiss_stale_sync'),
                  icon: const Icon(Icons.close),
                  label: const Text('Dismiss until tomorrow morning'),
                  onPressed: () {
                    ref.read(syncControllerProvider.notifier).dismissStaleness();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Dismissed until tomorrow morning'),
                        duration: Duration(seconds: 3),
                      ),
                    );
                  },
                ),
              ),
            ],
            // Hidden, not disabled, when there is nothing to sync: a "Sync
            // now" button on a project this device has stopped syncing would
            // be an offer the app cannot keep, and the card above has just
            // explained why. Task 11.12's "explain, don't hide" rule is about
            // controls somebody is not *allowed* to use; this one has nothing
            // to act on.
            if (status.isAvailable) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  FilledButton(
                    key: const ValueKey('sync_now'),
                    onPressed: status.running
                        ? null
                        : () => ref
                              .read(syncControllerProvider.notifier)
                              .syncNow(),
                    child: Text(status.running ? 'Syncing…' : 'Sync now'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              _FrequencySection(frequency: status.schedule.frequency),
            ],
          ],
        ),
      ),
    );
  }

  /// **What to do about the state above, in one exhaustive place.**
  ///
  /// This replaced two `if`s — "there is a remedy message" and "health ==
  /// broken" — that between them decided what a person read about a failed
  /// sync. Anything that fell past both got the `broken` sentence, and the
  /// `broken` sentence said *"Sync has failed repeatedly. If this continues,
  /// contact whoever manages your project server."* (now TriTrack support,
  /// task 11.324) **That is what somebody
  /// who had just left a project was told**: advice pointing away from the
  /// answer, for a state that was not a failure.
  ///
  /// A switch over [SyncHealth] rather than a chain of conditions, so a state
  /// added later cannot inherit somebody else's words by falling through. The
  /// states with nothing to add return null and say nothing, which is a
  /// decision here rather than an omission.
  List<Widget>? _advice(BuildContext context, SyncStatus status) {
    final theme = Theme.of(context);
    final (String text, Color? color)? advice = switch (status.health) {
      // The full sentence is `ServerUrlProblem.message`, which reaches here as
      // `lastErrorMessage` and is preferred over anything written below — see
      // the remedy branch at the end of this method. This is the fallback for
      // the one path that can set the health without the message: a round
      // classified from a `SyncTransportException`, where the reason travelled
      // and the prose did not.
      SyncHealth.serverAddressRefused => (
        'This device refuses the server address it has saved, so nothing has '
            'synced. It is not your network or the server: open More → Server '
            'Connection to see what to change. Nothing on this device has been '
            'changed or lost.',
        theme.colorScheme.error,
      ),
      // The full per-cause sentence — which of expired, self-signed, or
      // wrong-address it was — is `SyncTransportException.userMessage`, which
      // reaches here as `lastErrorMessage` and is preferred over this; see the
      // remedy branch at the end of this method. This is the fallback for a
      // round whose reason travelled and whose prose did not (task 11.113).
      SyncHealth.certificateRejected => (
        'The server was reached, but this device does not trust its security '
            'certificate, so nothing has synced. The certificate has to be '
            'fixed on the server — tell TriTrack support (More → App Info). '
            'Nothing on this device has been changed or lost.',
        theme.colorScheme.error,
      ),
      SyncHealth.membershipEnded => (
        // Says what happened, what it means for their data, and what it would
        // take to come back — because those are the three things somebody
        // asks in that order, and until now the app answered none of them.
        "You're no longer a member of this project — you left, or an owner "
            'removed you — so this device has stopped syncing it.\n\n'
            'Everything on this device stays and works offline. What you '
            'recorded stays in the project, still attributed to you.\n\n'
            'To rejoin, ask an owner to put you back, or for the project code '
            'to ask again.',
        null,
      ),
      SyncHealth.accessRefused => (
        // Names no cause, because this device genuinely cannot tell one:
        // the pull that would carry the news of a removal is the same
        // request being refused for somebody who was never on this project
        // at all — a phone still signed in under an account that belongs to
        // a different project (task 11.306). Both remedies are given,
        // likeliest first, so the one sentence is true for both people.
        'The server is refusing this device access to this project. That '
            'happens if an owner has removed you, or if this device is signed '
            'in to an account that was never on this project.\n\n'
            'If you expected to still be on it, ask an owner. If this is not '
            'your project, open one of your own.\n\n'
            'Nothing on this device has been changed or lost.',
        theme.colorScheme.error,
      ),
      SyncHealth.broken => (
        'Sync has failed repeatedly. If this continues, contact TriTrack '
            'support (More → App Info).',
        theme.colorScheme.error,
      ),
      // A dedicated sentence rather than nothing, because "24 hours" and
      // "04:00" are facts nobody could infer from the headline alone, and
      // this is the one place with room to say the dismiss control's own
      // rule (task 11.114).
      SyncHealth.staleRecordsPending || SyncHealth.staleNothingPending => (
        "This project hasn't synced in over 24 hours, though nothing has "
            'failed. Dismissing this shows the usual "last synced" line until '
            '4am tomorrow.',
        null,
      ),
      // Everything below has its own line elsewhere on this card, or nothing
      // to add. Listed rather than defaulted, so a new state is a compile
      // error here instead of silently inheriting a neighbour's advice.
      SyncHealth.versionRefused ||
      SyncHealth.sessionEnded ||
      SyncHealth.rowsRefused ||
      SyncHealth.recordsMissing ||
      SyncHealth.offline ||
      SyncHealth.healthy => null,
    };
    // The remedy text for a refusal that carries one is authored in
    // `SyncTransportException.userMessage` and selected by a refusal code, so
    // it is preferred over anything written here whenever it exists.
    final remedy = status.lastErrorMessage;
    if (remedy != null) {
      return [
        const SizedBox(height: 8),
        // Not in the error color when the refusal is a deleted project (task
        // 11.319): the sentence says nothing on this device is wrong, so a
        // red one would contradict itself. The other four refusals that
        // arrive here keep it.
        Text(
          remedy,
          style: status.refusedBecauseProjectDestroyed
              ? null
              : TextStyle(color: theme.colorScheme.error),
        ),
      ];
    }
    if (advice == null) return null;
    return [
      const SizedBox(height: 8),
      Text(advice.$1, style: TextStyle(color: advice.$2)),
    ];
  }

  /// What this card says when the failure above is one the app **has not
  /// tried since being told about** (task 11.116), or null when it has.
  ///
  /// **It reports what this device did, and makes no claim about the server.**
  /// "Still failing" and "may have recovered" are both statements about a
  /// server nobody has asked; "this app has not tried since" is a fact about
  /// this device, and it is the one that changes what somebody does next.
  String? _notRetriedLine() {
    final remembered = status.remembered;
    if (status.running || !status.failureIsRemembered || remembered == null) {
      return null;
    }
    final at = remembered.recordedAt.toLocal().toString().substring(0, 16);
    return 'From the last try, on $at. The app has not tried again since.';
  }

  /// The one sentence about a replaced server database (task 11.58), or null
  /// if this device has never found one under this project.
  ///
  /// **Kept, with its date, rather than shown for a while and then hidden.**
  /// It is one line on the screen a person opens to ask what happened, and a
  /// restore is rare enough that the most recent one is still the relevant
  /// one. Unlinking the project clears it.
  ///
  /// Names the two ordinary causes and asserts neither, because this device
  /// only knows the database is a different one — not how it came to be.
  String? _databaseChangedLine() {
    final at = status.serverDatabaseChangedAt;
    if (at == null) return null;
    final when = at.toLocal().toString().substring(0, 16);
    return "On $when the server's records had been replaced — restored from "
        'a backup, or rebuilt — so this device started syncing this project '
        'over from the beginning. Nothing recorded on this device was '
        'deleted.';
  }

  String _lastSyncedLine() {
    final last = status.lastSuccessAt;
    if (last == null) return "Hasn't synced yet.";
    return 'Last successful sync: ${last.toLocal().toString().substring(0, 16)}';
  }

  String _headline() => switch (status.health) {
    _ when status.running => 'Syncing…',
    SyncHealth.sessionEnded => 'Signed out',
    // **Never "Offline"** — the whole of task 11.104. The address, not the
    // network, and the headline has to say which.
    SyncHealth.serverAddressRefused => 'Server address refused',
    // **Never "Offline"** either, and for the same reason as the line above
    // (task 11.113): the network is working, and saying otherwise sends
    // somebody outside to look for signal they already have.
    SyncHealth.certificateRejected => 'Server certificate not trusted',
    // **Not a fixed "Update needed"** (task 11.303) — this state bundles
    // every refusal that has a remedy sentence, and only two of the five
    // codes that can reach it are actually about the app being out of date
    // (`cursor_too_old` and `rate_limited` are not). The headline is
    // declared beside the sentence, per code, in
    // `SyncTransportException.userHeadline` — never a second guess about
    // the same refusal written here.
    //
    // `lastErrorHeadline` is this session's own answer, when it has one.
    // Lacking that — a restart before this device tried again — falls back
    // to [syncRefusalHeadline] reading the durable record's raw code, and
    // only when neither survived does it say the generic "Sync refused".
    SyncHealth.versionRefused =>
      status.lastErrorHeadline ??
          syncRefusalHeadline(status.remembered?.stoppedReason),
    // **Not "You've left this project"** (task 11.60). Both ways out of a
    // project land here, and since the server now tells a removed member so
    // (§4.27), the removal direction is the one this headline is most often
    // read in — where "you left" names the wrong cause, which is the defect
    // task 11.54 existed to fix, one screen up.
    SyncHealth.membershipEnded => "You're not on this project",
    SyncHealth.accessRefused => 'Access refused',
    SyncHealth.broken => "Sync isn't working",
    // Never "Synced" while a record is held — the whole of finding D-3.
    SyncHealth.rowsRefused => 'Some records not synced',
    // And never "Synced" while a record the server sent was discarded, which
    // is the same rule pointed the other way (2026-08-27).
    SyncHealth.recordsMissing => 'Some records did not arrive',
    SyncHealth.offline => 'Offline',
    SyncHealth.healthy => 'Synced',
    // Never "Offline" and never "Synced": nothing has failed and the last
    // sync did succeed, so either word would be false. "Not synced" says
    // exactly what is true — task 11.114.
    SyncHealth.staleRecordsPending || SyncHealth.staleNothingPending =>
      'Not synced in over 24 hours',
  };

}

/// The records the server refused, why, and what to do about each one —
/// task 10.28's "the user is told, in the app, that something did not sync and
/// why."
///
/// Distinct from the "Overwritten edits" list below it in the one way that
/// matters: those records are on the server in a newer version, and these are
/// **on this device only**. The copy avoids the word "error" throughout — the
/// legitimate case (a colleague who is not on the project) is not a fault, and
/// nothing has been lost — while still refusing to describe it as synced.
class _HeldRowsSection extends ConsumerWidget {
  const _HeldRowsSection({required this.projectId, required this.held});

  final String projectId;
  final List<HeldRowDetail> held;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          'Waiting to sync',
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        const SizedBox(height: 4),
        // Leads with safety, not with the server's refusal — task 10.34.
        // Deliberately says nothing about *why* any of them are waiting:
        // until task 11.41 this sentence carried the guess ("most are simply
        // waiting on someone joining this project") because the cards below
        // could not carry the answer, and a summary that guesses on behalf of
        // rows it has not read is how a wrong cause gets believed. Each card
        // now says its own reason; this says only what is true of all of them.
        Text(
          'These records are safe on this device, and only here until they '
          'sync — keep it backed up. Each card says why and what to do.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        BoundedRecordList(
          total: held.length,
          noun: 'records',
          order: 'most recently refused first',
          builder: (limit) => [
            for (final detail in held.take(limit))
              _HeldRowTile(projectId: projectId, detail: detail),
          ],
        ),
      ],
    );
  }
}

/// **Task 10.87 — the bound every one-card-per-record section on this screen
/// shares.** Draws the first [shownByDefault] of [total], says so, and offers
/// the rest on request.
///
/// The three sections here were built for the occasional refused, dropped or
/// overwritten record and were correct at that size. A project import can
/// produce thousands of them at once — nothing lost, and unreadable — and a
/// list that draws all of them is the consent dialog's "forty then a wall"
/// with the forty removed. The rule this enforces, derived rather than fixed
/// per section: **a bound, a stated total, and an order the incoming file
/// cannot choose.** The order is [order], stated on screen so a person knows
/// what the first twenty *are*; it is the store's `ORDER BY` on a timestamp
/// this device wrote, which is what makes it not the file's to choose.
///
/// *Show all* builds every card. That is a choice the person makes, once,
/// knowing the number — the opposite of the screen making it for them.
class BoundedRecordList extends StatefulWidget {
  const BoundedRecordList({
    super.key,
    required this.total,
    required this.noun,
    required this.order,
    required this.builder,
  });

  final int total;

  /// Plural noun for the count sentence — "records".
  final String noun;

  /// The order the first cards are in, in words.
  final String order;

  /// Builds the first [limit] cards.
  final List<Widget> Function(int limit) builder;

  static const int shownByDefault = 20;

  @override
  State<BoundedRecordList> createState() => _BoundedRecordListState();
}

class _BoundedRecordListState extends State<BoundedRecordList> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final bounded = !_all && widget.total > BoundedRecordList.shownByDefault;
    final limit = bounded ? BoundedRecordList.shownByDefault : widget.total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bounded)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Showing the first $limit of ${widget.total} ${widget.noun}, '
              '${widget.order}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ...widget.builder(limit),
        if (bounded)
          TextButton(
            onPressed: () => setState(() => _all = true),
            child: Text('Show all ${widget.total}'),
          ),
      ],
    );
  }
}

/// One held record: **which record, which rule held it, and what to do** —
/// the three things task 11.41 found this tile did not say.
///
/// What it printed before was the table name ("Tags", "Users"), one paragraph
/// covering three unrelated causes, and a retry button. The banner promised a
/// reason and this was the screen that was meant to give it, so the promise
/// was not kept — and on real hardware that cost a diagnosis outright.
///
/// The three lines below are labelled, in these words, because a person
/// reading a red card is looking for exactly them and should not have to
/// extract them from prose.
class _HeldRowTile extends ConsumerStatefulWidget {
  const _HeldRowTile({required this.projectId, required this.detail});

  final String projectId;
  final HeldRowDetail detail;

  @override
  ConsumerState<_HeldRowTile> createState() => _HeldRowTileState();
}

class _HeldRowTileState extends ConsumerState<_HeldRowTile> {
  bool _retrying = false;

  /// **Task 11.236: a tap that cannot finish must say so.** Before this, a
  /// failure inside [heldRowRetryProvider] left the spinner stopping, the
  /// record still refused, and no sync started — with nothing on screen, the
  /// same silent-failure shape task 11.235 fixed on the tag database's +
  /// button. The row is not lost either way (the release already happened),
  /// but a person who tapped and saw nothing had no way to tell that from a
  /// worse failure, and nothing told them to try again.
  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await ref.read(heldRowRetryProvider)(
        widget.projectId,
        widget.detail.held,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              describeFailure(e, fallback: kHeldRowRetryFailedMessage),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final row = detail.held;
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Which record. Never an id where a name exists — "Users" told
            // nobody which person.
            Text(
              detail.recordLabel,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            // Which rule. Stated as a fact about this record, not as the
            // server's reason — the server answers one opaque refusal for
            // every cause on purpose (§4.13), so claiming to report it would
            // be the screen inventing a certainty it does not have.
            Text('Why it is waiting', style: theme.textTheme.labelLarge),
            Text(detail.heldBy),
            const SizedBox(height: 8),
            Text('What you can do', style: theme.textTheme.labelLarge),
            Text(detail.whatYouCanDo),
            const SizedBox(height: 8),
            Text(
              'Last tried '
              '${row.lastRefusedAtUtc.toLocal().toString().substring(0, 16)}'
              '${row.refusalCount > 1 ? ' · ${row.refusalCount} attempts' : ''}'
              ' · ${_humanTableName(row.tableName)} · ${row.rowKey}',
              style: theme.textTheme.bodySmall,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: _retrying
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  // A plain `TextButton` inherits the app's brand-green
                  // foreground everywhere, which read as green text on this
                  // card's red `errorContainer` fill — hard to see, and the
                  // only way to act on a held record. `onErrorContainer` is
                  // the color Material 3 pairs with `errorContainer` for
                  // exactly this reason.
                  : TextButton(
                      onPressed: detail.recordExists ? _retry : null,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.onErrorContainer,
                      ),
                      child: const Text('Try again'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Kept, and moved to the end of the card rather than the top of it. The
  /// table name and row key are what somebody would have to quote in a bug
  /// report; they are not what the person reading the card needs first.
  String _humanTableName(String tableName) =>
      tableName.replaceAll('_', ' ').trim();
}

/// The records the server sent that this device refused to store, why, and
/// what that means — task 11.44's durable, named answer to what used to be
/// only a count that reset on restart.
///
/// The inbound mirror of [_HeldRowsSection], distinguished from it — and from
/// "Overwritten edits" below — the same way [SyncStatus.droppedOnArrivalCount]
/// is distinguished from [SyncStatus.heldCount]: a held record exists on this
/// device and nowhere else, and a dropped one is everywhere *except* this
/// device. There is no "Try again" here, unlike [_HeldRowTile]: the pull that
/// skipped this record has already moved past it, and this app has no action
/// that re-asks the server for it.
class _DroppedRowsSection extends StatelessWidget {
  const _DroppedRowsSection({required this.dropped});

  final List<DroppedRow> dropped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          'Records that did not arrive',
          style: theme.textTheme.titleMedium?.copyWith(
            color: Colors.orange.shade800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Nothing has been lost: these records are safe on the server, but '
          'this device does not have them. Each card says why.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        BoundedRecordList(
          total: dropped.length,
          noun: 'records',
          order: 'most recently refused first',
          builder: (limit) => [
            for (final row in dropped.take(limit)) _DroppedRowTile(row: row),
          ],
        ),
      ],
    );
  }
}

/// One dropped record: **which record, which rule refused it, and what to
/// do** — the same three things [_HeldRowTile] states, read here from
/// [DroppedRowDetails] instead of a resolved local row, because there is no
/// local row to resolve.
class _DroppedRowTile extends StatelessWidget {
  const _DroppedRowTile({required this.row});

  final DroppedRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              DroppedRowDetails.recordLabel(row),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text('Why it did not arrive', style: theme.textTheme.labelLarge),
            Text(DroppedRowDetails.reason(row)),
            const SizedBox(height: 8),
            Text('What you can do', style: theme.textTheme.labelLarge),
            Text(DroppedRowDetails.whatYouCanDo(row)),
            const SizedBox(height: 8),
            Text(
              'Last happened '
              '${row.lastDroppedAtUtc.toLocal().toString().substring(0, 16)}'
              '${row.dropCount > 1 ? ' · ${row.dropCount} times' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// **What "how often" can honestly mean here** (task 11.59).
///
/// The control and the two sentences under it are one unit and are written
/// together on purpose. Automatic sync only ever attempts while the app is
/// foregrounded — task 10.8 decided against background sync with reasons, and
/// iOS would run it seldom on a phone that spends the day in a pack — so a
/// heading of "Sync every 15 minutes" would describe a timer this app does not
/// have. The heading is therefore about *while TriTrack is open*, and the note
/// says outright that a closed app syncs at no setting.
///
/// The second sentence is the cost of the feature rather than a footnote:
/// automatic sync is **not** Wi-Fi-only. `sync_schedule.dart` explains why no
/// connectivity plugin is used, and names turning automatic sync off as the
/// remedy — so somebody being handed a frequency control needs that sentence
/// in front of them, next to the choice that is the remedy.
class _FrequencySection extends ConsumerWidget {
  const _FrequencySection({required this.frequency});

  final SyncFrequency frequency;

  /// What each choice costs or saves, in the terms somebody picking it cares
  /// about. Null where the name says it all.
  static String? _note(SyncFrequency f) => switch (f) {
    // Named, because this is the option that gives up the fifteen-minute
    // floor `minimumInterval` exists for: field use crosses between the map
    // and the record screen constantly, and each crossing becomes a round
    // trip.
    SyncFrequency.everyForeground =>
      'A round trip each time you come back to the app. Most up to date, '
          'most battery and data.',
    SyncFrequency.everyFifteenMinutes => null,
    SyncFrequency.hourly => 'Fewer round trips on a metered or satellite plan.',
    SyncFrequency.onlyWhenIAsk =>
      'Nothing syncs on its own. Your records stay on this device until you '
          'tap Sync now.',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text('Sync while TriTrack is open', style: theme.textTheme.titleSmall),
        RadioGroup<SyncFrequency>(
          groupValue: frequency,
          onChanged: (value) {
            if (value == null) return;
            ref.read(syncControllerProvider.notifier).setFrequency(value);
          },
          child: Column(
            children: [
              for (final option in SyncFrequency.values)
                RadioListTile<SyncFrequency>(
                  key: ValueKey('sync_frequency_${option.id}'),
                  value: option,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    option == defaultSyncFrequency
                        ? '${option.label} (recommended)'
                        : option.label,
                  ),
                  subtitle: switch (_note(option)) {
                    final note? => Text(note),
                    _ => null,
                  },
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'It does not sync in the background: while the app is closed, '
          'nothing syncs at any of these settings.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Automatic sync uses any connection, including cellular data. '
          'There is no Wi-Fi-only setting yet. On a metered or satellite '
          'plan, choose "${SyncFrequency.onlyWhenIAsk.label}".',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// One import or one sync round's overwrites, as one card — task 10.87. See
/// [SyncConflictEvent] for why the grouping, and for what bounds the card.
///
/// The card's face says how many records and of which kinds, which is the
/// whole answer for an event of one; opened, it lists a sample of
/// [shownPerEvent] records in the declared table order **and says how many it
/// is not showing**, because a sample presented as the list is the defect the
/// 40-item consent dialog had. *Got it* acknowledges the whole event.
class ConflictEventCard extends ConsumerWidget {
  const ConflictEventCard({
    super.key,
    required this.projectId,
    required this.event,
  });

  final String projectId;
  final SyncConflictEvent event;

  /// Records listed by name inside one opened event before the rest are
  /// stated as a number. Every record stays in the table; this bounds what
  /// is *drawn*, not what is kept.
  static const int shownPerEvent = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final when = event.detectedAtUtc.toLocal().toString().substring(0, 16);
    final byTable = event.countByTable;
    final kinds = [
      for (final e in byTable.entries) ConsentSummary.countOf(e.key, e.value),
    ].join(', ');
    final shown = event.conflicts.take(shownPerEvent).toList();
    final hidden = event.count - shown.length;
    return Card(
      child: ExpansionTile(
        title: Text(
          '${event.count} ${event.count == 1 ? 'record' : 'records'} '
          'overwritten',
        ),
        subtitle: Text('$when · $kinds'),
        children: [
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Showing the first ${shown.length} of ${event.count}. All '
                '${event.count} previous versions are kept on this device.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (final conflict in shown)
            _ConflictTile(conflict: conflict),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () =>
                    markSyncConflictEventReviewed(ref, projectId, event),
                child: Text(
                  event.count == 1 ? 'Got it' : 'Got it — all ${event.count}',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConflictTile extends StatelessWidget {
  const _ConflictTile({required this.conflict});

  final SyncConflict conflict;

  @override
  Widget build(BuildContext context) {
    final changed = conflict.changedFields;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ExpansionTile(
        dense: true,
        title: Text(ConsentSummary.tableLabel(conflict.tableName)),
        subtitle: Text(conflict.rowKey, maxLines: 1, overflow: TextOverflow.ellipsis),
        children: [
          if (changed.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('The replacement value could not be determined.'),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final field in changed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _humanFieldName(field.field),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text('Your edit: ${field.was ?? '(empty)'}'),
                          Text(
                            'Kept instead: ${field.replacedBy ?? '(empty)'}',
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _humanFieldName(String field) => field.replaceAll('_', ' ');
}

import 'package:flutter/material.dart';

import '../core/providers/sync_provider.dart';
import '../data/sync/sync_schedule.dart';

/// **How severe a sync state is, in the four levels a glance can carry.**
///
/// Task 11.189 replaced the shell's sync bar — a coloured strip above every
/// tab — with one small icon on the map and a dot on the More tab. A strip
/// had a sentence; an icon has a colour and a shape, so the thirteen
/// [SyncHealth] states have to collapse into something a person can read
/// without reading. This is that collapse, and it is **derived from the same
/// switch that writes the sentence** ([SyncStatusPresentation.of]) rather
/// than being a second opinion about the same states.
///
/// ## What Michael asked for, 2026-09-07
///
/// *"a little green check when everything is okay, a yellow warning for
/// delayed sync and a red exclamation point when things were bad."* Those are
/// [healthy], [warning] and [fault]. [quiet] is the fourth, and it is the one
/// that is not in his list because it is not a verdict at all.
enum SyncSeverity {
  /// **The only green in the app.** Reached from [SyncHealth.healthy] and
  /// nothing else: a green tick is a claim that a sync succeeded, and every
  /// other state here is a state where one did not.
  healthy,

  /// **Neither a fault nor health, and deliberately not amber.**
  ///
  /// [SyncHealth.offline] is *the normal condition of this app* — a field day
  /// is mostly dead zones — and an amber warning for it would cry wolf every
  /// time somebody walked out of signal. [SyncHealth.running] is a round in
  /// flight, which is not a verdict either. [SyncHealth.membershipEnded] is
  /// here for task 11.54's reason: being removed from a project, or leaving
  /// one, is somebody's decision rather than a fault, and a red bar for it
  /// was the single most misleading thing this surface ever did.
  ///
  /// **Grey is not "fine".** It is visibly not the green tick, and the glyph
  /// under it says which of the three it is — a crossed-out cloud, a spinning
  /// sync, a door out. What it does not do is raise an alarm about something
  /// nobody needs to act on right now.
  quiet,

  /// Something is behind or refused, and the records at stake are safe
  /// somewhere else — a teammate's record that did not arrive, a signed-out
  /// session, a project the server would not serve.
  warning,

  /// **A record is on this device and nowhere else, or nothing is getting
  /// through and will not until somebody changes something.** The states that
  /// mean data is stranded, or that this build refuses the server address, or
  /// that its certificate is rejected.
  fault;

  /// The colour of the icon at this severity.
  ///
  /// These are the shades the sync bar used for the same states before task
  /// 11.189, so nothing a person had learned to read changed except the shape
  /// it is drawn in — with the one deliberate exception that [healthy] became
  /// green, which is what it already was on the sync status screen.
  Color get color => switch (this) {
    SyncSeverity.healthy => Colors.green.shade600,
    SyncSeverity.quiet => Colors.blueGrey.shade700,
    SyncSeverity.warning => Colors.orange.shade800,
    SyncSeverity.fault => Colors.red.shade800,
  };

  /// The shape that says the severity on its own, for the three levels that
  /// are a verdict — or null for [quiet], which is not one.
  ///
  /// **Shape as well as colour, on purpose.** Roughly one man in twelve
  /// cannot tell this amber from this red, and the whole value of a 28-pixel
  /// icon is that it is read at a glance rather than compared. A [quiet]
  /// state has no verdict to draw, so it shows what it *is* instead — see
  /// [SyncStatusPresentation.glyph].
  IconData? get verdictGlyph => switch (this) {
    SyncSeverity.healthy => Icons.check_circle,
    SyncSeverity.warning => Icons.warning_amber_rounded,
    SyncSeverity.fault => Icons.error,
    SyncSeverity.quiet => null,
  };
}

/// **What one sync state looks like and says, decided in exactly one place.**
///
/// ## Why this file exists
///
/// Until task 11.189 there were two exhaustive switches over the thirteen
/// [SyncHealth] states: `SyncStatusBanner._presentation`, which chose a
/// colour, an icon and a sentence for the strip above every tab, and
/// `SyncStatusScreen`'s `_icon()`/`_color()`, which chose them again for the
/// card you reached by tapping it. They agreed on twelve of the thirteen and
/// disagreed on [SyncHealth.healthy] — grey on the bar, green on the card —
/// and nothing would ever have said so.
///
/// The bar is gone and the icon that replaced it needs a *severity*, which
/// the brief for that task was explicit about: derive it from the switch that
/// already assigns the colour, **so the icon and the sentence behind it
/// cannot disagree.** So the switch moved here, both surfaces read it, and
/// the second list of thirteen is deleted rather than kept in step by hand.
///
/// ## It is exhaustive, and that is the guard
///
/// A state added to [SyncHealth] without a decision here does not fall into a
/// default and quietly acquire a neighbour's colour: it fails to compile.
/// That is the same property `SyncStatus.health` relies on one layer down.
class SyncStatusPresentation {
  const SyncStatusPresentation({
    required this.severity,
    required this.icon,
    required this.message,
  });

  final SyncSeverity severity;

  /// The icon for *this state*, as opposed to for its severity — a crossed-out
  /// cloud for offline, a broken link for a refused address, a door for a
  /// membership that ended. Used by the sync status screen's card, which has
  /// room to be specific, and by [glyph] for the [SyncSeverity.quiet] states.
  final IconData icon;

  /// **The sentence.** One line, written for a person who is looking at it
  /// for two seconds: what is wrong, and what to do.
  ///
  /// It reaches a sighted person as the icon's tooltip and a VoiceOver user as
  /// its accessibility label; the whole story is on `SyncStatusScreen`, one
  /// tap away, which is where a colour was always going to send somebody
  /// anyway. **These sentences were written for a strip that ellipsised on a
  /// phone** (tasks 11.104 and 11.113), which is why the first four words of
  /// the two configuration failures deny the network — that constraint is
  /// gone and the words are kept, because they are still the right words and
  /// re-writing reviewed copy for no reason is how copy gets worse.
  final String message;

  /// The shape the status icon draws: the verdict glyph where there is a
  /// verdict, and the state's own icon where there is not.
  IconData get glyph => severity.verdictGlyph ?? icon;

  /// The colour the status icon draws in.
  Color get color => severity.color;

  /// **The one switch.** Moved verbatim from `SyncStatusBanner._presentation`
  /// by task 11.189, with each case's `Colors.…` replaced by the
  /// [SyncSeverity] it stood for, and [SyncHealth.healthy] promoted from grey
  /// to [SyncSeverity.healthy].
  static SyncStatusPresentation of(SyncStatus status) {
    final (severity, icon, baseText) = _presentation(status);
    return SyncStatusPresentation(
      severity: severity,
      icon: icon,
      message: _tensed(baseText, status),
    );
  }

  /// Adds the tense when the failure being reported is one this app **has not
  /// tried since being told about** (task 11.116).
  ///
  /// ## Why one appended clause rather than eight rewritten sentences
  ///
  /// Every state below already says the right thing about *what* is wrong.
  /// What a remembered failure changes is *when this app last checked*, which
  /// is the same fact in every state — so it is written once, here, rather
  /// than as a second variant of each sentence that could drift out of step
  /// with the first.
  ///
  /// ## Why "last tried", not "still failing" or "may have recovered"
  ///
  /// Both of those are claims about the server, and this device has not asked
  /// it. "Last tried" is a fact about this device, which is the only thing it
  /// can honestly report.
  static String _tensed(String text, SyncStatus status) {
    // **Never while a round is in flight.** "Syncing…" and "not retried
    // since" are contradictory sentences, and the round about to finish is
    // precisely the re-test this clause exists to say has not happened yet.
    if (status.running) return text;
    final remembered = status.remembered;
    if (!status.failureIsRemembered || remembered == null) return text;
    return '$text Last tried ${_relative(remembered.recordedAt)} — '
        'not retried since.';
  }

  static (SyncSeverity, IconData, String) _presentation(SyncStatus status) {
    if (status.running) {
      return (SyncSeverity.quiet, Icons.sync, 'Syncing…');
    }
    switch (status.health) {
      case SyncHealth.serverAddressRefused:
        // **A fault, and the first four words deny the network** (task
        // 11.104). Whatever a person reads first has to be the part that
        // stops them walking outside looking for signal. The state it
        // replaced read "Offline — last synced 5 min ago", which is a
        // sentence about a network that was working.
        //
        // `link_off` rather than `cloud_off`: every cloud icon on this
        // surface means "no connection", which is the reading being
        // corrected.
        return (
          SyncSeverity.fault,
          Icons.link_off,
          'Not a network problem — this app build refuses the server address. '
              'Tap for what to change.',
        );
      case SyncHealth.certificateRejected:
        // **A fault, and the first four words deny the network** — the same
        // sentence shape task 11.104 established one case up, for the same
        // reason (task 11.113). The state it replaced read "Offline — last
        // synced 21 hr ago" on an iPhone whose own browser was refusing that
        // server's certificate by name.
        //
        // Deliberately short: the per-cause sentence — expired, self-signed,
        // wrong address — is long, and it is on the screen this taps through
        // to, where there is room for it.
        return (
          SyncSeverity.fault,
          Icons.gpp_bad,
          "Not a network problem — this device doesn't trust the server's "
              'security certificate. Tap for what needs fixing.',
        );
      case SyncHealth.sessionEnded:
        return (
          SyncSeverity.warning,
          Icons.lock_outline,
          'Signed out — tap to sign in and resume syncing.',
        );
      case SyncHealth.versionRefused:
        // **Quiet for one of the five refusals that land here** (task
        // 11.319): an owner destroyed the project on the server. Its
        // sentence says nothing is wrong on this device, and being sent away
        // from a project by somebody's decision is what
        // [SyncHealth.membershipEnded] already draws in gray. The other four
        // — a version skew either way, a device away too long, a server
        // that does not offer the route — are faults and stay so.
        return (
          status.refusedBecauseProjectDestroyed
              ? SyncSeverity.quiet
              : SyncSeverity.fault,
          Icons.error_outline,
          status.lastErrorMessage ?? 'Sync needs an update.',
        );
      case SyncHealth.membershipEnded:
        // **Quiet, and it does not say "error".** Leaving a project is
        // something a person chose; being removed from one is somebody else's
        // decision about them. Neither is a fault of this app or this device,
        // and a red bar here was the single most misleading thing the sync
        // surface did (task 11.54).
        //
        // Quiet is not silent: the icon is grey rather than green, and its
        // glyph is a door out rather than a crossed-out cloud, so it can be
        // told apart from being offline at a glance.
        return (
          SyncSeverity.quiet,
          Icons.logout,
          "You're no longer on this project, so it has stopped syncing. "
              'Tap for what that means.',
        );
      case SyncHealth.accessRefused:
        // A warning rather than a fault: the likeliest cause is an ordinary
        // administrative one — somebody removed this person from the project
        // — and this device cannot yet tell that from a server fault, so it
        // must not present either as established.
        return (
          SyncSeverity.warning,
          Icons.lock_outline,
          'The server is refusing access to this project. Tap to check.',
        );
      case SyncHealth.broken:
        return (
          SyncSeverity.fault,
          Icons.error_outline,
          "Sync isn't working. Tap to check.",
        );
      case SyncHealth.rowsRefused:
        // A fault, and it says the number: this is the one state that means a
        // primary record exists on this device and nowhere else. The old
        // behaviour here was a green "Synced" (task 10.28 / finding D-3).
        return (
          SyncSeverity.fault,
          Icons.warning_amber_rounded,
          _refusedText(status),
        );
      case SyncHealth.recordsMissing:
        // A warning rather than a fault, and it says the number. Nothing is
        // lost — the records are on the server and on whoever wrote them —
        // but this device does not have them, and before 2026-08-27 this
        // state showed a plain "Synced" while the pull discarded them.
        return (
          SyncSeverity.warning,
          Icons.warning_amber_rounded,
          _missingText(status),
        );
      case SyncHealth.offline:
        return (
          SyncSeverity.quiet,
          Icons.cloud_off,
          _lastSyncedText(status),
        );
      case SyncHealth.staleRecordsPending:
        // A fault, and it leads with the count — task 11.114. Records waiting
        // exist on this device and nowhere else, which is the same severity
        // [SyncHealth.rowsRefused] carries, even though nothing here has
        // actually been refused: staleness alone is the finding.
        return (
          SyncSeverity.fault,
          Icons.cloud_off,
          _staleText(status, hasPending: true),
        );
      case SyncHealth.staleNothingPending:
        // A warning: this device has nothing of its own waiting, so the risk
        // is only that it is missing teammates' records, not that its own are
        // stranded — the same distinction that makes
        // [SyncHealth.recordsMissing] a warning rather than a fault.
        return (
          SyncSeverity.warning,
          Icons.cloud_off,
          _staleText(status, hasPending: false),
        );
      case SyncHealth.healthy:
        // **The only green.** Everything above is a state in which a sync did
        // not succeed, and a tick claiming otherwise is the lie this whole
        // surface has spent six tasks removing.
        return (
          SyncSeverity.healthy,
          _healthyIcon(status),
          _healthyText(status),
        );
    }
  }

  /// A crossed-out sync icon when nothing automatic is going to happen, for
  /// the same reason [_healthyText] changes its words.
  static IconData _healthyIcon(SyncStatus status) {
    if (!status.schedule.automaticEnabled) return Icons.sync_disabled;
    return status.pendingCount > 0
        ? Icons.cloud_upload_outlined
        : Icons.cloud_done_outlined;
  }

  static String _refusedText(SyncStatus status) {
    final noun = status.heldCount == 1 ? 'record' : 'records';
    final verb = status.heldCount == 1 ? "isn't" : "aren't";
    return '${status.heldCount} $noun $verb on the server. '
        'Tap to see why.';
  }

  static String _missingText(SyncStatus status) {
    final n = status.droppedOnArrivalCount;
    final noun = n == 1 ? 'record' : 'records';
    return "$n $noun the server sent could not be read by this app. "
        'Tap to see why.';
  }

  static String _staleText(SyncStatus status, {required bool hasPending}) {
    // `status.lastSuccessAt` is always non-null here: [SyncStatus.health]
    // can only reach [SyncHealth.staleRecordsPending] or
    // [SyncHealth.staleNothingPending] by comparing it against 24 hours, so
    // the fallback below is defensive rather than a state this app produces.
    final last = status.lastSuccessAt;
    final since = last == null ? 'a while' : _staleDuration(last);
    if (hasPending) {
      final n = status.pendingCount;
      final noun = n == 1 ? 'record is' : 'records are';
      return 'Not synced in $since — $n $noun only on this device.';
    }
    return "Not synced in $since. You may be missing teammates' records.";
  }

  /// A plain "3 days" / "36 hours" — deliberately not [_relative]'s "3 days
  /// ago", which reads wrong ahead of "Not synced in".
  static String _staleDuration(DateTime last) {
    final diff = DateTime.now().toUtc().difference(last.toUtc());
    if (diff.inDays >= 1) {
      return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'}';
    }
    return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'}';
  }

  static String _lastSyncedText(SyncStatus status) {
    final last = status.lastSuccessAt;
    final base = last == null
        ? "Offline — hasn't synced yet"
        : 'Offline — last synced ${_relative(last)}';
    return '$base.${_manualOnlyNote(status)}';
  }

  static String _healthyText(SyncStatus status) {
    final last = status.lastSuccessAt;
    final base = last == null
        ? "Hasn't synced yet"
        : 'Synced ${_relative(last)}';
    final pending = status.pendingCount;
    final noun = pending == 1 ? 'record' : 'records';
    // **It says when nothing is going to happen** (task 11.59).
    //
    // "3 records waiting to sync" on a device with automatic sync switched
    // off tells somebody the app is about to do something it never will —
    // exactly the silence tasks 11.54, 11.57 and this one have been taking
    // out of this surface. Turning it off is legitimate; leaving the old
    // sentence up while it is off is not, so the count leads and the setting
    // follows it immediately.
    if (!status.schedule.automaticEnabled) {
      if (pending <= 0) return '$base ·${_manualOnlyNote(status)}';
      return '$pending $noun waiting — sync is '
          '"${SyncFrequency.onlyWhenIAsk.label}". Tap to sync.';
    }
    if (pending <= 0) return '$base.';
    return '$base · $pending $noun waiting to sync.';
  }

  /// The setting named in the user's own words, or nothing at all.
  ///
  /// The words come from [SyncFrequency.onlyWhenIAsk] rather than being
  /// written here, so this sentence and the sync screen's radio button cannot
  /// come to say different things.
  static String _manualOnlyNote(SyncStatus status) =>
      status.schedule.automaticEnabled
          ? ''
          : ' Sync is "${SyncFrequency.onlyWhenIAsk.label}".';

  static String _relative(DateTime at) {
    final diff = DateTime.now().toUtc().difference(at.toUtc());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    if (diff.inDays < 7) {
      return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
    }
    return 'on ${at.toLocal().toString().substring(0, 10)}';
  }
}

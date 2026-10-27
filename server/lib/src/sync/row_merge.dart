/// The server's side of last-write-wins (task 10.5).
///
/// **This delegates every ordering decision to the shared `MergeResolver` and
/// must keep doing so.** Writing the comparison as SQL —
/// `WHERE incoming.revision > existing.revision OR (... AND updated_at > ...)`
/// — is the tempting version and is forbidden: it would be a *second*
/// implementation of the merge rule, and a client and server that disagree
/// about which row wins produce split-brain, where two devices converge on
/// different states depending on which one synced through the server. Avoiding
/// exactly that is why `packages/tritrack_sync` exists (task 10.1). Reading
/// the existing row and calling the shared resolver costs a round trip; that
/// is the price of the guarantee.
library;

import 'package:tritrack_sync/tritrack_sync.dart';

import 'clock_skew.dart';
import 'revision_plausibility.dart';

/// What the server should do with one incoming row.
enum MergeAction {
  /// No server copy exists; insert it.
  insert,

  /// The incoming copy wins last-write-wins; overwrite the server's.
  update,

  /// The server's copy is newer or identical; leave it alone. The row still
  /// counts as "seen" for reporting, and — importantly — **its `server_seq` is
  /// not bumped**, because nothing about the stored row changed and bumping it
  /// would redeliver an unchanged row to every other device forever.
  skip,
}

/// The decision for one incoming row, plus everything the caller needs to
/// record it.
class MergeDecision {
  const MergeDecision({
    required this.action,
    required this.skewFlag,
    this.revisionVerdict,
    this.blockingRowVerdict,
    this.losingRow,
  });

  final MergeAction action;

  /// What the server concluded about the *incoming* row's `revision`, or null
  /// when the claim is explainable (task 11.159).
  ///
  /// **Carried out of the decision without affecting it.** Nothing here
  /// changes which row wins: a row whose merge clock cannot be explained is
  /// merged exactly as it would have been, stored exactly as it would have
  /// been, and recorded. Refusing it would strand a field record on the
  /// strength of a guess about how many times somebody edits a row — see
  /// `RevisionPlausibility` for the measurement that settled that, and for why
  /// bounding the *increment* instead does not survive contact with an offline
  /// burst or with an insert.
  final RevisionVerdict? revisionVerdict;

  /// What the server concluded about the **stored** row's own `revision`, set
  /// only when [action] is [MergeAction.skip] — that is, when the incoming row
  /// lost to it.
  ///
  /// **This is the only thing that can see a pin that predates the detection.**
  /// [revisionVerdict] judges a row as it arrives, so a register built on it
  /// alone would hold nothing about a row pinned before this code shipped,
  /// and its count of zero would read as "there are none". A push losing to
  /// an unexplainable stored row is both the evidence that the pin exists and
  /// the moment it costs somebody a correction.
  final RevisionVerdict? blockingRowVerdict;

  /// Clock-skew classification of the *incoming* row, recorded whether or not
  /// the row wins — a device with a broken clock is worth knowing about even
  /// when its rows lose.
  final ClockSkewFlag? skewFlag;

  /// The server copy that lost, when [action] is [MergeAction.update].
  ///
  /// Carried out of the decision because "rows that lost last-write-wins" is
  /// the single most useful line in the diagnostics console (10.13) and the
  /// raw material for the user-visible conflict record in 10.12 — "my
  /// observation disappeared" is the bug that actually gets reported, and a
  /// merge that silently discards the loser leaves nothing to answer it with.
  final Map<String, Object?>? losingRow;

  bool get changesStoredRow => action != MergeAction.skip;
}

abstract final class RowMerge {
  /// Decides the fate of [incoming] given the server's [existing] copy (null
  /// if the server has never seen this row).
  ///
  /// [receivedAt] is the server's clock reading for this sync, used only for
  /// skew classification — never to modify the row.
  static MergeDecision decide({
    required Map<String, Object?> incoming,
    required Map<String, Object?>? existing,
    required DateTime receivedAt,
  }) {
    final skewFlag = ClockSkew.classifyRow(incoming, receivedAt: receivedAt);
    // Classified for every action, including a row that loses: a device
    // pushing a revision nobody can account for is worth knowing about whether
    // or not that particular row won, exactly as a broken clock is.
    final revisionVerdict = RevisionPlausibility.classify(
      incoming: incoming,
      existing: existing,
    );

    if (existing == null) {
      return MergeDecision(
        action: MergeAction.insert,
        skewFlag: skewFlag,
        revisionVerdict: revisionVerdict,
      );
    }
    if (MergeResolver.incomingWins(incoming, existing)) {
      return MergeDecision(
        action: MergeAction.update,
        skewFlag: skewFlag,
        revisionVerdict: revisionVerdict,
        losingRow: existing,
      );
    }
    return MergeDecision(
      action: MergeAction.skip,
      skewFlag: skewFlag,
      revisionVerdict: revisionVerdict,
      // The stored row judged on its own claim — `existing` measured against
      // nothing, i.e. against its own `created_at`..`updated_at` span. This is
      // the row that just won, so if its revision cannot be accounted for, the
      // push that lost is evidence of a pin.
      blockingRowVerdict: RevisionPlausibility.classify(
        incoming: existing,
        existing: null,
      ),
    );
  }
}

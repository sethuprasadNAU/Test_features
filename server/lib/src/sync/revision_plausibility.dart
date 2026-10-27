/// Detection — never refusal — for a `revision` no honest edit can overtake
/// (task 11.159).
///
/// ## The finding
///
/// `MergeResolver` decides last-write-wins on `revision` first. A row pushed at
/// a very large `revision` therefore wins **every** future merge: a teammate's
/// genuine correction, arriving at `revision: 8`, is reported to them as
/// *"Unchanged (local was newer)"* and discarded, forever. Task 11.158 gave
/// `revision` a floor (a negative one loses every merge, including against its
/// own holder's next edit) and deliberately flagged this ceiling rather than
/// guessing at a number for it.
///
/// ## Why nothing here refuses anything
///
/// **A ceiling cannot be both safe and effective, and that is a fact about the
/// harm rather than about any particular number.** The harm is
/// *unovertakability*, and it begins many orders of magnitude below any bound
/// that would be safe to enforce: `revision: 1000000` pins a field observation
/// exactly as permanently as `2^62` does, while sitting far below every
/// absolute bound this project has ever declared. So a bound high enough that
/// no honest row can trip it does not prevent the pin, and a bound low enough
/// to prevent the pin is a guess about how many times a row is edited over its
/// life — which strands somebody's irreplaceable field record the first time
/// the guess is low.
///
/// Bounding the *increment* instead — refusing a push more than N above the
/// revision the server already holds — was the candidate task 11.159 was given
/// to evaluate, on the argument that a delta only has to anticipate one push.
/// **`test/data/sync/offline_revision_burst_test.dart` measured it and the
/// argument does not survive:**
///
/// - The push offers a row's **current state**, never an edit log. Fifty edits
///   made in a dead zone arrive as **one row advanced by fifty**, so the delta
///   is the number of corrections somebody made between two syncs — a guess
///   about how long a person is off the network, which is a ceiling wearing a
///   different hat.
/// - A batch limit bounds how many *rows* a push carries and cannot bound how
///   far *one* row has moved; there is no history on the wire to split.
/// - **A delta is blind exactly where the pin is cheapest.** A row the server
///   has never seen is an insert, and an insert has no existing revision to be
///   measured against. A first push at `2^62` passes a delta bound without it
///   ever being consulted.
/// - The app itself admits `revision: 3999000000` on the share/import path
///   (§4.19 clause 3's own ceiling) and then pushes it verbatim, so any server
///   ceiling below that number would strand a row the app consented to hold.
///
/// **The asymmetry decides it.** Refusing wrongly strands an irreplaceable
/// field record silently, behind a red bar nobody can clear; noticing wrongly
/// costs one row in a server-only table. The likelier cause is a client bug —
/// an uninitialised value, an overflow, a bad import — and the person holding
/// the broken client is not an attacker. So this classifies and records, and
/// the row is **always stored**, exactly as `ClockSkew` classifies a bad clock
/// without ever rewriting a timestamp.
///
/// ## What the threshold is derived from, since it is not a lifetime guess
///
/// `revision` counts edits, and an edit is a person tapping Save. A row also
/// carries the span those edits are claimed to have happened in — `created_at`
/// to `updated_at` for a row the server has never seen, and the stored
/// `updated_at` to the incoming one for a row it already holds. So the question
/// is not *"is this number too big"* (a lifetime guess) but **"could this many
/// edits have been made in the time the row itself claims they took"** — which
/// is answered from state already on the row.
///
/// That leaves one parameter, an edit *rate*, and it is bounded by physiology
/// rather than by domain judgement. See [maxEditsPerSecond].
library;

/// What the server concluded about an incoming row's `revision`.
enum RevisionAnomaly {
  /// The row claims more edits than the span it says they happened in could
  /// hold — see [RevisionPlausibility.plausibleEdits]. This is the whole of
  /// the classification today; it is an enum so that a second, differently
  /// derived signal can be added beside it without the recording side, the
  /// diagnostics query or the operator report changing shape.
  impossibleEditRate('impossible_edit_rate');

  const RevisionAnomaly(this.db);

  /// Stored value for the anomaly log's `anomaly` column.
  final String db;

  static RevisionAnomaly? fromDb(String? value) =>
      value == null ? null : values.firstWhere((a) => a.db == value);
}

/// One row's `revision` claim, classified.
class RevisionVerdict {
  const RevisionVerdict({
    required this.anomaly,
    required this.claimedEdits,
    required this.allowedEdits,
    required this.spanSeconds,
    required this.storedRevision,
    required this.incomingRevision,
  });

  final RevisionAnomaly anomaly;

  /// How many edits the row claims to have made in [spanSeconds] — the whole
  /// `revision` for a row the server has never seen, and the advance over the
  /// stored one otherwise.
  final int claimedEdits;

  /// The most [spanSeconds] could account for. Recorded beside [claimedEdits]
  /// so a person reading the log can see *how far past* plausible the row is
  /// without re-deriving the rule — a finding, not a name.
  final int allowedEdits;

  final int spanSeconds;

  /// The revision the server held before this push, or null on an insert.
  final int? storedRevision;

  final int incomingRevision;
}

abstract final class RevisionPlausibility {
  /// The most edits per second this treats as possible, sustained across a
  /// row's whole claimed span.
  ///
  /// **One.** A person correcting an observation opens a screen, changes a
  /// field and saves; doing that once per second without pause for the entire
  /// life of a row is already far beyond anything a human does, and the number
  /// is deliberately loose in the direction that costs nothing. Being too
  /// generous means a pinned row goes unflagged, which is exactly the state
  /// this project is in today; being too tight would put a line in a table
  /// about a legitimate row, which costs a person nothing and is why a rate can
  /// be chosen here at all. **Neither error can strand a record**, because
  /// nothing on this path refuses anything.
  ///
  /// Contrast `UntrustedImportRules.maxImportedRevision`, where the same kind
  /// of number *does* gate a refusal and had to reserve headroom for a
  /// device's own future edits. The looseness here is affordable for precisely
  /// the reason the strictness there was mandatory.
  static const int maxEditsPerSecond = 1;

  /// Edits allowed regardless of span, so that a row whose whole life is a few
  /// seconds is not flagged for being young.
  ///
  /// A thousand, the magnitude
  /// `UntrustedImportRules.maxUnexplainedRevisionAdvance` already argues for on
  /// the import path: *a row a person has edited a thousand times is not a
  /// field record*. Deliberately the same number rather than a fresh one — the
  /// question it answers is the same question, and two numbers meaning "more
  /// corrections than a field record has" would be two numbers to keep true.
  static const int burstAllowance = 1000;

  /// The most edits [spanSeconds] can account for.
  ///
  /// A negative span — an `updated_at` before the `created_at` it is measured
  /// from — is clamped to zero rather than trusted; `ClockSkew` already
  /// classifies that row separately, and letting a backwards clock *buy*
  /// allowance would make the two signals fight.
  static int plausibleEdits(int spanSeconds) {
    if (spanSeconds <= 0) return burstAllowance;
    // Saturating rather than overflowing: a span of a few hundred million
    // seconds times a rate of one is nowhere near 2^63, but the addition is
    // written so that a hostile `created_at` cannot wrap the allowance
    // negative and turn this check into permission.
    final scaled = spanSeconds * maxEditsPerSecond;
    if (scaled < 0) return burstAllowance;
    return burstAllowance + scaled;
  }

  /// Classifies [incoming]'s `revision` against the server's [existing] copy
  /// (null when the server has never seen this row). Returns null when the
  /// claim is explainable.
  ///
  /// **Both cases ask one question in two framings.** For a row the server
  /// already holds, the edits in question are the advance over the stored
  /// revision and the span is from the stored `updated_at` to the incoming
  /// one. For a row it has never seen, the edits are the whole revision and
  /// the span is the row's own `created_at` to `updated_at`. An insert is
  /// therefore covered, which is the case a bound on the increment cannot
  /// reach at all.
  static RevisionVerdict? classify({
    required Map<String, Object?> incoming,
    required Map<String, Object?>? existing,
  }) {
    final incomingRevision = _revision(incoming);
    if (incomingRevision == null) return null;

    final storedRevision = existing == null ? null : _revision(existing);
    final int claimedEdits;
    final DateTime? from;
    if (existing == null || storedRevision == null) {
      claimedEdits = incomingRevision;
      from = _parseUtc(incoming['created_at']);
    } else {
      claimedEdits = incomingRevision - storedRevision;
      from = _parseUtc(existing['updated_at']);
    }
    // A row that did not move the clock forward is not making a claim about
    // edits at all — it loses or ties, and `MergeResolver` handles it.
    if (claimedEdits <= 0) return null;

    final to = _parseUtc(incoming['updated_at']);
    // No usable span means no basis for a verdict. Deliberately silent rather
    // than assuming the worst: a row whose timestamps will not parse is a
    // `RowValidator` matter, and answering "implausible" here would send a
    // reader after the wrong thing — the wrong-cause class this project keeps
    // finding.
    if (from == null || to == null) return null;

    final spanSeconds = to.difference(from).inSeconds;
    final allowed = plausibleEdits(spanSeconds);
    if (claimedEdits <= allowed) return null;

    return RevisionVerdict(
      anomaly: RevisionAnomaly.impossibleEditRate,
      claimedEdits: claimedEdits,
      allowedEdits: allowed,
      spanSeconds: spanSeconds < 0 ? 0 : spanSeconds,
      storedRevision: storedRevision,
      incomingRevision: incomingRevision,
    );
  }

  static int? _revision(Map<String, Object?> row) {
    final value = row['revision'];
    return value is int ? value : null;
  }

  static DateTime? _parseUtc(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value)?.toUtc();
  }
}

import 'db_codec.dart';
import 'field_time_zone.dart';
import 'schema_constants.dart';

/// **Michael's interlock — one animal wears one collar at a time, and one
/// collar is on one animal at a time** (task 11.243,
/// `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §6, tightened by §6a).
///
/// His words, 2026-09-13:
///
/// > *"Put an interlock on the animal such that it can't have two tags linked
/// > to it unless the tags attached/removed dates don't overlap by more than
/// > one day (old tags are replaced by new tags on the same day). A tag can
/// > only have one [animal] that is currently on it per the tag dates. If a
/// > user tries to link a tag to an animal with dates that overlap by more
/// > than one day it tells the user to fix the removed/attached dates of the
/// > tags."*
///
/// And on 2026-09-16, withdrawing the allowance (§6a):
///
/// > *"What if we just enforce a rule that every animal in the list can't
/// > have more than one tag attached and can't have more than one tag with
/// > removal times that overlap or the same."*
///
/// Two constraints and **no tolerance** (task 11.263):
///
/// - an animal's deployments may not overlap at all;
/// - a tag's deployments may not overlap at all.
///
/// **The one-day allowance existed because a deployment could not say
/// when.** Both collars on a handover day were stamped *the 15th*, so they
/// had to be allowed to share the 15th. Task 11.251 gave a swap a time — the
/// old collar ends at 14:32 and the new one starts at 14:32, an overlap of
/// zero — and the allowance was left reachable only by recording a same-day
/// removal as a bare day, which is exactly the route by which two rows came
/// to cover one moment with nothing to say which animal a bearing belonged
/// to. Closing the route means the app can no longer create that state.
///
/// **It refuses; it never adjusts.** A link that would violate either is
/// turned away with the dates named, because silently moving a date somebody
/// wrote down is how a field note becomes wrong with nobody making a mistake.
///
/// ## What "overlap" means here — the same thing it means to a bearing
///
/// Two deployments overlap when **some moment is inside both**, read the way
/// `Deployment.coversMoment` reads a row (design §4a): a date-only end covers
/// the whole of its day, and an end with a time on it is an instant. So:
///
/// - removed *the 15th* (a bare day) and attached *the 15th* (a bare day)
///   **overlap** — both cover the whole of the 15th, and a bearing taken at
///   2 p.m. would be inside both;
/// - removed *the 15th at 14:32* and attached *the 15th at 14:32* **do not**
///   — an instant has no width to share, and each bearing that day is inside
///   exactly one of them;
/// - removed *the 15th* (a bare day) and attached *the 16th* do not — the
///   15th ends where the 16th begins.
///
/// Reading the dates as bare instants, the way this rule did until task
/// 11.263, called the first and second cases the same thing: two intervals
/// touching at midnight. That is what let the ambiguous state through.
///
/// ## Why this is one function that both sides call
///
/// **A rule enforced on one device is a rule about that device, not about the
/// record** (§6). The device refuses at the point of the link so a person
/// finds out while they are looking at the two dates; the server refuses the
/// same row arriving over the wire, because a device is untrusted and a
/// second implementation of the rule is a second answer to it. Same shape as
/// `isSelfDeparture` and `MergeResolver`: one function, two enforcers, no
/// possibility of disagreement.
///
/// **It governs writes, not reads** (task 11.263, design §9). A row that
/// this rule would now refuse can already be stored — written by a build
/// with the one-day allowance, or by hand-typed dates on one — and nothing
/// migrates or deletes it. Every reader keeps reading it: `coversMoment`
/// answers for it, and a moment two such rows both cover is reported as
/// *contested* (§4a) rather than picked. The rule fires only when a
/// deployment is linked, edited or pushed.
///
/// ## Each row's days are read in the row's own zone (task 11.331)
///
/// [deploymentEndHasTime] tells a bare day from an instant by asking whether
/// the value sits at the start of its day **in the zone the row was written
/// in** — `Deployments.time_zone`, the project's zone at that moment
/// (schema v20). That question has one answer on every device and on the
/// server, so the rule below is the same rule everywhere for every row that
/// carries a zone.
///
/// **Until task 11.331 the question was asked in the reading process's own
/// zone**, which was exact only on the phone that wrote the row. The server
/// runs on UTC, so a bare day written at Arizona midnight arrived as 07:00
/// and read there as a time, and a swap at exactly 17:00 in Arizona read as
/// a UTC bare day — one hand-picked swap time in 24 (tasks 11.264 and
/// 11.266). Task 11.266 stopped the second by making the server read every
/// end as an instant; that flag survives as [conflictFor]'s
/// `zonelessEndsAreInstants`, and **it now applies only to a row with no
/// zone** — one pushed by a build older than v20, or naming a zone this
/// build's tz database does not hold. For those rows the server still gives
/// up what 11.266 wrote down: a same-day handover recorded as two bare days
/// by an old build reads there as two instants touching and is let through.
/// Every overlap that does not depend on the day-or-time question is still
/// refused: two open-ended collars on one animal, a collar on two animals
/// for a week, a link back-dated into another.
///
/// ## Two rows written in different zones
///
/// A project's zone can change mid-season, and each row keeps the zone it
/// was written in, so one animal can hold a row read in Arizona and the next
/// read in Denver. **Where both ends being compared are bare days, they are
/// compared as days** — the 15th ends before the 16th begins, whichever
/// zone each was written in — because "recorded days stay the same days" is
/// the promise the zone change makes (§4). Where either end carries a time,
/// the two are compared as instants, with the bare one read as the start or
/// end of its day in its own zone. In one zone the two readings are the
/// same rule; [overlaps] is where they meet.
///
/// ## What a null date means, and it is not "unknown at both ends"
///
/// - **`attachedDate == null` covers no interval and conflicts with
///   nothing.** Nobody has said when the collar went on, so nothing can be
///   said about which bearings it covers or which other deployment it
///   overlaps. This is counter-intuitive and it is the design (§4); it is
///   asserted, not left to be discovered.
/// - **`removedDate == null` means still on**, so the interval runs from the
///   attached date forever. Two open-ended deployments of one collar — or on
///   one animal — therefore overlap infinitely and are refused, which is the
///   case the interlock is most obviously for.
/// - **A tombstone constrains nothing and is constrained by nothing.** In
///   either position — stored or arriving — a withdrawn link frees both
///   ends, and refusing the withdrawal itself would close the only repair a
///   person has for a pair the rule refuses.
abstract final class DeploymentInterlock {
  /// Whether [candidate] may be stored given [existing] — every other
  /// deployment in the same project, tombstones included or not at the
  /// caller's discretion.
  ///
  /// Returns null when it may, and a [DeploymentConflict] naming the first
  /// row it collides with when it may not. **The first, not all of them**:
  /// the person fixes one pair of dates and asks again, and a list of
  /// conflicts sorted by nothing in particular is harder to act on than the
  /// one that is in the way.
  ///
  /// [existing] is expected to exclude [candidate] itself; a row whose
  /// `deployment_id` matches is skipped anyway, so re-checking an edit of a
  /// stored row does not find the row conflicting with its own former self.
  ///
  /// [zonelessEndsAreInstants] is the server's flag (task 11.266, narrowed
  /// by task 11.331 to rows with no zone) — see [coverageEnd] and the class
  /// comment's "own zone" section for what it changes and what it gives up.
  /// The device never passes it: a zoneless row on a device was written by a
  /// build that read it in the device's own zone, which is the reading the
  /// device still gives it.
  static DeploymentConflict? conflictFor(
    DeploymentInterval candidate,
    Iterable<DeploymentInterval> existing, {
    bool zonelessEndsAreInstants = false,
  }) {
    // A deployment with no attached date covers no interval, so nothing can
    // overlap it — in either direction. Checked once here rather than inside
    // the loop so the reason is stated where it can be read.
    if (candidate.attachedDate == null) return null;
    // **A withdrawn link cannot create an overlap**, so a tombstone arriving
    // is never refused. Found by task 11.263: the loop below has always
    // skipped a *stored* tombstone, and nothing asked whether the *candidate*
    // was one — so the server refused a withdrawal whenever the row being
    // withdrawn overlapped something, which is exactly when a person needs
    // to withdraw it. The device never asks this of a tombstone (its unlink
    // goes straight to the soft delete); the server asks it of every row.
    if (candidate.deleted) return null;
    for (final other in existing) {
      if (other.deploymentId == candidate.deploymentId) continue;
      if (other.deleted) continue;
      if (other.attachedDate == null) continue;
      final sharesAnimal = other.individualId == candidate.individualId;
      final sharesTag = other.tagId == candidate.tagId;
      if (!sharesAnimal && !sharesTag) continue;
      if (!overlaps(
        candidate,
        other,
        zonelessEndsAreInstants: zonelessEndsAreInstants,
      )) {
        continue;
      }
      return DeploymentConflict(
        other: other,
        // An overlap that is both is reported as the animal's, because that
        // is the sentence Michael wrote the rule as and it is the one a
        // person is more likely to be looking at.
        subject: sharesAnimal
            ? DeploymentConflictSubject.animal
            : DeploymentConflictSubject.tag,
      );
    }
    return null;
  }

  /// **Whether some moment is inside both [a] and [b]** — the whole of the
  /// rule since task 11.263, with each end read as `Deployment.coversMoment`
  /// reads it (see the class comment).
  ///
  /// False when either has no attached date (it covers no interval), and
  /// false when the two merely meet: a timed end at the instant the next one
  /// starts, or a bare day ending where the next day begins.
  ///
  /// [zonelessEndsAreInstants] is passed straight to [coverageEnd] — see its
  /// doc and the class comment for what it changes.
  static bool overlaps(
    DeploymentInterval a,
    DeploymentInterval b, {
    bool zonelessEndsAreInstants = false,
  }) {
    if (a.attachedDate == null || b.attachedDate == null) return false;
    // Some moment is inside both exactly when each starts before the other
    // ends — and before its own end, so that a row whose removal precedes
    // its attachment covers nothing, as it always has. **Both still on** —
    // two open-ended intervals — passes all four, which is the case the rule
    // is most obviously for: a reading that treated "no end" as "no
    // overlap" would permit exactly what Michael described, and it did,
    // once, until a test caught it.
    final flag = zonelessEndsAreInstants;
    return _startsBeforeEnd(a, a, flag) &&
        _startsBeforeEnd(b, b, flag) &&
        _startsBeforeEnd(a, b, flag) &&
        _startsBeforeEnd(b, a, flag);
  }

  /// Whether [starting]'s attached date comes before the end of what
  /// [ending] covers (task 11.331).
  ///
  /// **Two bare days are compared as days**, each read in its own row's
  /// zone: a collar attached on the 16th starts after one removed on the
  /// 15th, whichever zone each row was written in. In one zone that is
  /// exactly the instant comparison below (the 16th's start is the 15th's
  /// coverage end); across zones it is what keeps "recorded days stay the
  /// same days" true after a project's zone changes mid-season. **Anything
  /// carrying a time is compared as instants**, with a bare start read as the
  /// start of its day and a bare end as the start of the next, each in its
  /// own row's zone.
  static bool _startsBeforeEnd(
    DeploymentInterval starting,
    DeploymentInterval ending,
    bool zonelessEndsAreInstants,
  ) {
    final start = starting.attachedDate!;
    final end = ending.removedDate;
    if (end == null) return true;
    final startIsDay =
        !_readsAsInstants(starting, zonelessEndsAreInstants) &&
        !deploymentEndHasTime(start, _zoneOf(starting));
    final endIsDay =
        !_readsAsInstants(ending, zonelessEndsAreInstants) &&
        !deploymentEndHasTime(end, _zoneOf(ending));
    if (startIsDay && endIsDay) {
      return !fieldCalendarDate(
        start,
        _zoneOf(starting),
      ).isAfter(fieldCalendarDate(end, _zoneOf(ending)));
    }
    final coverage = coverageEnd(
      ending,
      zonelessEndsAreInstants: zonelessEndsAreInstants,
    )!;
    return start.isBefore(coverage);
  }

  /// The zone [interval]'s days are read in — its own, when this build
  /// knows it; null (the reading process's zone) otherwise.
  static String? _zoneOf(DeploymentInterval interval) =>
      FieldTimeZone.isKnown(interval.timeZone) ? interval.timeZone : null;

  /// Whether every end of [interval] is the instant it holds — true only
  /// for the server's flag on a row with no zone it can read.
  static bool _readsAsInstants(
    DeploymentInterval interval,
    bool zonelessEndsAreInstants,
  ) => zonelessEndsAreInstants && _zoneOf(interval) == null;

  /// **The first moment [interval] no longer covers**, or null for still on.
  ///
  /// A timed end is that instant — the deployment is half-open there,
  /// `[start, end)`, so a bearing at exactly the swap time belongs to the
  /// incoming collar. A bare day covers the whole of itself, so its coverage
  /// ends where the next day begins **in the row's own zone** — which on a
  /// daylight-saving day is 23 or 25 hours later, not 24. This is
  /// `coversMoment`'s rule written as a boundary rather than as a predicate,
  /// and the two are held to agree by `deployment_interval_test.dart`.
  ///
  /// **[zonelessEndsAreInstants] skips the bare-day widening for a row with
  /// no zone** — such a removal is its own instant, never rounded up to the
  /// next day. This is the server's flag (task 11.266, narrowed by task
  /// 11.331): a row without a zone was written at the midnight of whichever
  /// phone typed it, and the server's process is never that phone. A row
  /// with a zone is read the same way by everyone, so the flag does not
  /// touch it. The device passes false — a zoneless row on a device is read
  /// in the device's zone, as the build that wrote it read it.
  static DateTime? coverageEnd(
    DeploymentInterval interval, {
    bool zonelessEndsAreInstants = false,
  }) {
    final removed = interval.removedDate;
    if (removed == null) return null;
    if (_readsAsInstants(interval, zonelessEndsAreInstants)) return removed;
    final zone = _zoneOf(interval);
    if (deploymentEndHasTime(removed, zone)) return removed;
    return deploymentNextDayFor(removed, zone);
  }

  /// The columns this rule reads, as a row straight off the wire or the
  /// database. Returns null when the row is not shaped like a deployment at
  /// all — `RowValidator` has already refused such a row, and guessing here
  /// would make the interlock's answer depend on a parse nobody checked.
  static DeploymentInterval? intervalFromRow(Map<String, Object?> row) {
    final id = row['deployment_id'];
    final tagId = row['tag_id'];
    final individualId = row['individual_id'];
    if (id is! String || tagId is! String || individualId is! String) {
      return null;
    }
    return DeploymentInterval(
      deploymentId: id,
      tagId: tagId,
      individualId: individualId,
      attachedDate: DbCodec.decodeUtcOrNull(row['attached_date']),
      removedDate: DbCodec.decodeUtcOrNull(row['removed_date']),
      deleted: row['deleted_at'] != null,
      // Absent on a row from a build older than schema v20, and on a v19
      // server's row: read as null, which is what it means.
      timeZone: row['time_zone'] is String ? row['time_zone'] as String : null,
    );
  }

  /// The table this rule is about, so a caller can compare against it without
  /// repeating the name.
  static const String table = Tables.deployments;

  /// **This rule's own identity on the wire** (task 11.267).
  ///
  /// A `RowRefusal` answers *"which column's declared bound did this row
  /// break"*; an interlock answers *"which named rule about the project's
  /// other rows did this row break"* — a different question, and this is the
  /// interlock's answer to it, carried beside `SyncPushResponse.outcomes`
  /// rather than folded into `RowRefusal`'s vocabulary (see that type's
  /// header for why a hand-picked code there is exactly what it exists to
  /// avoid).
  ///
  /// **Declared here, beside the rule, rather than typed at the refusal
  /// site.** The device does not need this value to say anything about the
  /// dates or the other row — it already holds both deployments and can run
  /// [conflictFor] itself, the same way a local link attempt does. All this
  /// string has to do is tell the device *which* shared rule fired, so it
  /// knows to ask itself that question rather than falling through to the
  /// honest default. A second interlock, if one is ever added, gets its own
  /// identity from its own declaration instead of a string picked by hand at
  /// a call site that has to remember not to collide with this one.
  static const String ruleId = 'deployment_interlock';
}

// `deploymentDateFor` and `deploymentEndHasTime` moved to
// `field_time_zone.dart` with task 11.331, which gave both a zone; the
// package exports them from there.

/// The four columns the interlock reads, plus the tombstone.
///
/// A value type rather than the model class because the server has no model
/// classes and the rule must be the same function on both sides.
class DeploymentInterval {
  const DeploymentInterval({
    required this.deploymentId,
    required this.tagId,
    required this.individualId,
    this.attachedDate,
    this.removedDate,
    this.deleted = false,
    this.timeZone,
  });

  final String deploymentId;
  final String tagId;
  final String individualId;

  /// Null covers no interval — see [DeploymentInterlock].
  final DateTime? attachedDate;

  /// Null means still on.
  final DateTime? removedDate;

  /// **The zone this row's days were written in** (task 11.331, schema v20)
  /// — an IANA name such as `America/Phoenix`, the project's zone at the
  /// moment the row was written. A bare day is the start of its day *here*.
  ///
  /// Null for a row written before v20 (or by an older build since), and
  /// read as null when it names a zone this build does not know: such a row
  /// is read in the reading process's own zone, except by the server, which
  /// reads its ends as instants (`zonelessEndsAreInstants`).
  final String? timeZone;

  /// A tombstoned deployment constrains nothing: it is a record that the link
  /// was withdrawn, and the whole point of withdrawing it is to free both
  /// ends.
  final bool deleted;
}

/// Which of the two constraints an overlap breaks.
enum DeploymentConflictSubject {
  /// This animal would be wearing two collars at once.
  animal,

  /// This collar would be on two animals at once.
  tag,
}

/// Why a deployment was refused — the row it collides with.
///
/// **It carries the other row rather than a sentence.** The wording belongs to
/// the device: the server may not send prose to a client screen (Security
/// Model §4.13), and the device is the only side that can put the tag's name
/// and the animal's name into it.
///
/// It no longer carries a count of overlapping days (task 11.263): with no
/// tolerance there is no number to compare against, and the sentence a
/// person needs names the two dates, not the width between them.
class DeploymentConflict {
  const DeploymentConflict({required this.other, required this.subject});

  final DeploymentInterval other;
  final DeploymentConflictSubject subject;

  @override
  String toString() =>
      'deployment ${other.deploymentId} overlaps on the ${subject.name}';
}

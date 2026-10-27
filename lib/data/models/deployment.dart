import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'sync_meta.dart';

// **`deploymentDateFor` and `deploymentEndHasTime` moved to the shared
// package with task 11.263** — `packages/tritrack_sync/lib/src/
// deployment_interlock.dart`, beside the interlock, which now has to tell a
// bare day from a time in order to refuse a same-day handover recorded as two
// bare days (design §6a). Their doc comments went with them, including the
// reopen triggers design §4a names on `deploymentEndHasTime`: a build without
// task 11.251's change found in the field beside one with it, and the first
// crew whose devices span time zones. Re-exported here so every reader in
// `lib/` and `test/` that imported them from this file still finds them —
// and so does `deployment_linking.dart`, which re-exports this file.
export 'package:tritrack_sync/tritrack_sync.dart'
    show
        deploymentDateFor,
        deploymentEndHasTime,
        deploymentNextDayFor,
        fieldCalendarDate,
        fieldDayStart,
        fieldInstant,
        fieldWallClock;

part 'deployment.freezed.dart';

/// **A tag on an animal, between two dates** — task 11.243,
/// `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §4.
///
/// A [Tag] is a transmitter somebody owns; an [Individual] is an animal
/// somebody studies; this is the fact that connects them, and it has dates
/// because that connection ends. It existed as three columns on `Tags`
/// between schema v9 and v16, which made the equipment inventory and the
/// deployment record the same row — so a refurbished collar could only be
/// expressed by inventing a second collar.
///
/// **What this buys, which is the argument for the whole change (§2):**
///
/// 1. A bearing gets its animal from **time**, not from a pointer. Correcting
///    these dates re-attributes exactly the window corrected and nothing else
///    — no bearing is ever rewritten.
/// 2. A collar that falls off and keeps transmitting produces bearings that
///    fall outside every deployment, so the animal is honestly **unknown**
///    rather than being credited to whoever wore it last.
/// 3. Michael's interlock is an interval rule, which is natural here and was
///    only half-expressible on a column. See [DeploymentInterlock].
///
/// **There is no `lineage_id`** — unlike [Tag] and [Individual]. A deployment
/// is a fact inside one project: *this* project's collar on *this* project's
/// animal. Nothing about it is shared between two projects, so there is
/// nothing for a lineage to identify. A season clone (task 11.56) copies
/// deployments and re-points both ends.
@freezed
abstract class Deployment with _$Deployment {
  const Deployment._();

  const factory Deployment({
    required String deploymentId,

    /// The project both ends live in. Part of the key.
    required String projectId,

    /// The collar. A same-project reference into `Tags`.
    required String tagId,

    /// The animal. A same-project reference into `Individuals`.
    required String individualId,

    /// When the collar went on, or **null where nobody wrote it down** —
    /// Michael, 2026-09-13: *"It is okay to make the tag put on date and tag
    /// off dates empty."*
    ///
    /// **A deployment with no attached date covers no interval, so it
    /// attributes no bearings and conflicts with nothing.** That is the
    /// correct consequence of not knowing when it started, and it is
    /// counter-intuitive enough that it is asserted rather than left to be
    /// met: see `DeploymentRepository.animalForObservation` and
    /// `DeploymentInterlock`.
    DateTime? attachedDate,

    /// When the collar came off, or **null for still on**. Null is not
    /// "unknown" here: an open-ended deployment covers everything from
    /// [attachedDate] onward, which is why two of them on one animal are
    /// refused by the interlock.
    DateTime? removedDate,
    String? notes,
    required SyncMeta sync,

    /// **The zone this row's days were written in** (task 11.331, schema
    /// v20) — the project's zone at the moment the row was written. A bare
    /// day in [attachedDate] or [removedDate] is the start of that day in
    /// this zone, so the row reads as the same day on every phone and on the
    /// server. **Kept when the project's zone changes later**: a row's days
    /// do not move.
    ///
    /// Null for a row from a build older than v20; it is then read in this
    /// phone's own zone, which is how that build read it.
    String? timeZone,
  }) = _Deployment;

  /// **Whether a record taken at the instant [at] falls inside this
  /// deployment** — the attribution question, design §4a (task 11.251).
  ///
  /// Each end is read one of two ways, and [deploymentEndHasTime] is the
  /// whole of the distinction:
  ///
  /// - **A date-only end covers the whole of its day.** Attached on the 3rd
  ///   and removed on the 9th means the 3rd through the 9th *inclusive* —
  ///   a bearing taken at 2 p.m. on the 9th, hours before the collar came
  ///   off, is inside. Before this rule the end was read as the instant the
  ///   day *began*, so every bearing taken on the day a collar came off was
  ///   attributed to nobody, and on a same-day swap to the next animal
  ///   instead. Michael saw both on his map, 2026-09-15.
  /// - **An end with a time on it is an instant, and beats the day.** A
  ///   same-day swap recorded through the §5a confirmation stamps the same
  ///   instant on the outgoing deployment's end and the incoming one's
  ///   start, so `[start, end)` at that instant hands each bearing to
  ///   exactly one of them. Half-open only *here*: an instant has no width
  ///   to share, whereas a day does.
  ///
  /// **Two date-only deployments can therefore both cover one moment** — a
  /// row from a build with the one-day allowance, or one written in another
  /// zone (§4). This method answers only for its own row;
  /// `DeploymentRepository.animalForObservationIn` is what notices the
  /// overlap and reports the moment as **contested** rather than picking.
  /// **Since task 11.263 this app cannot write such a pair** — the interlock
  /// refuses any overlap, read exactly the way this method reads an end
  /// (`DeploymentInterlock.overlaps`) — but a pair that already exists is
  /// still read honestly, because the interlock governs writes, not reads.
  ///
  /// Every reader asks this same moment question: the Log's and the Map's
  /// animal filters, the Map's colour, the Record wheel (`tagIdsAudibleOn`),
  /// and the interlock's own arithmetic.
  ///
  /// **Days are read in [timeZone]** (task 11.331): a bearing at 23:30 in
  /// the field on the day a collar came off is inside, wherever the phone
  /// reading it is. A project whose zone changed keeps each row's own zone,
  /// so at the edge of a day a row written under the old zone ends at the
  /// old zone's midnight — the boundary moves by the zones' difference,
  /// usually an hour, for that row only.
  bool coversMoment(DateTime at) {
    final from = attachedDate;
    if (from == null) return false;
    final zone = timeZone;
    if (deploymentEndHasTime(from, zone)) {
      if (at.isBefore(from)) return false;
    } else if (deploymentDateFor(
      at,
      zone,
    ).isBefore(deploymentDateFor(from, zone))) {
      return false;
    }
    final until = removedDate;
    if (until == null) return true;
    if (deploymentEndHasTime(until, zone)) return at.isBefore(until);
    return !deploymentDateFor(at, zone).isAfter(deploymentDateFor(until, zone));
  }

  /// The start of the field day [at] falls on, in this row's zone.
  DateTime dayOf(DateTime at) => deploymentDateFor(at, timeZone);

  /// Whether [end] (one of this row's dates) carries a time, read in this
  /// row's zone.
  bool endHasTime(DateTime end) => deploymentEndHasTime(end, timeZone);

  /// The calendar date [at] falls on in this row's zone, for a picker or a
  /// label — never the reading phone's date.
  DateTime calendarDateOf(DateTime at) => fieldCalendarDate(at, timeZone);

  /// This row as the shared interlock reads it.
  DeploymentInterval get interval => DeploymentInterval(
    deploymentId: deploymentId,
    tagId: tagId,
    individualId: individualId,
    attachedDate: attachedDate,
    removedDate: removedDate,
    deleted: sync.deletedAt != null,
    timeZone: timeZone,
  );

  factory Deployment.fromRow(Map<String, Object?> row) => Deployment(
    deploymentId: row['deployment_id'] as String,
    projectId: row['project_id'] as String,
    tagId: row['tag_id'] as String,
    individualId: row['individual_id'] as String,
    attachedDate: DbCodec.decodeUtcOrNull(row['attached_date']),
    removedDate: DbCodec.decodeUtcOrNull(row['removed_date']),
    notes: row['notes'] as String?,
    sync: SyncMeta.fromRow(row),
    timeZone: row['time_zone'] as String?,
  );

  Map<String, Object?> toColumns() => {
    'deployment_id': deploymentId,
    'project_id': projectId,
    'tag_id': tagId,
    'individual_id': individualId,
    'attached_date': DbCodec.encodeUtcOrNull(attachedDate),
    'removed_date': DbCodec.encodeUtcOrNull(removedDate),
    'notes': notes,
    ...sync.toColumns(),
    'time_zone': timeZone,
  };
}

/// **Which animal a record was about, or that the question has no single
/// answer** — what `DeploymentRepository.animalForObservationIn` returns
/// since task 11.251.
///
/// Three states, and **no getter hands back one animal for a contested
/// moment**: a reader has to say what it does with more than one candidate,
/// because the whole defect this replaced was a derivation that returned the
/// first match in a list and let four screens believe it. [sole] is null
/// unless there is exactly one; [candidates] is the list; [mayBe] is the
/// question the Log's and the Map's animal filters actually ask.
class AnimalAttribution {
  const AnimalAttribution._(this.candidates);

  /// No live deployment covers the moment — a collar in the box, or one that
  /// fell off and kept transmitting. Design §2's honest answer.
  static const nobody = AnimalAttribution._([]);

  /// Exactly one animal.
  AnimalAttribution.to(String individualId)
    : candidates = List.unmodifiable([individualId]);

  /// Whichever of [nobody], [to] or contested the ids amount to, with
  /// duplicates collapsed — two deployments of one collar on the *same*
  /// animal that both cover the moment (a pair from a build with the
  /// one-day allowance) are one answer, not a contest.
  factory AnimalAttribution.among(Iterable<String> individualIds) {
    final distinct = <String>[];
    for (final id in individualIds) {
      if (!distinct.contains(id)) distinct.add(id);
    }
    if (distinct.isEmpty) return nobody;
    return AnimalAttribution._(List.unmodifiable(distinct));
  }

  /// Distinct animals whose deployments cover the moment, in the order the
  /// deployments were handed in. Empty for [nobody].
  final List<String> candidates;

  /// The one animal, or null when there is none or more than one.
  String? get sole => candidates.length == 1 ? candidates.single : null;

  /// **More than one deployment covers this moment**, and the derivation
  /// refuses to choose (design §4a). A reader shows it neutrally — the Map
  /// draws the neutral swatch and the legend says so; the Log lists the
  /// record under every candidate.
  bool get isContested => candidates.length > 1;

  bool get isNobody => candidates.isEmpty;

  /// Whether [individualId] is, or may be, the animal — true for a sole
  /// match and for a contested moment that names it.
  bool mayBe(String individualId) => candidates.contains(individualId);

  @override
  String toString() => isNobody
      ? 'AnimalAttribution.nobody'
      : isContested
      ? 'AnimalAttribution.contested($candidates)'
      : 'AnimalAttribution.to(${candidates.single})';
}

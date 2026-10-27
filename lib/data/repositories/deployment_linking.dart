import 'package:sqflite/sqflite.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:uuid/uuid.dart';

import '../../core/time/project_time_zone.dart';
import '../db/data_arrival.dart';
import '../models/deployment.dart';
import '../models/sync_meta.dart';
import '../models/tag.dart';
import '../models/tag_library_entry.dart';
import 'deployment_repository.dart';
import 'individual_repository.dart';
import 'mutation_authorization.dart';
import 'project_repository.dart';
import 'tag_repository.dart';

// `deploymentDateFor` and `deploymentEndHasTime` live in the shared package
// beside the interlock since task 11.263 (they were on the model from task
// 11.251 until then); the model re-exports them and so does this file, so the
// screens that import it for the date still find it here.
export '../models/deployment.dart'
    show deploymentDateFor, deploymentEndHasTime, fieldCalendarDate;

/// **Putting a collar on an animal, and taking the last one off in the same
/// breath** — task 11.244, `ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §5a.
///
/// Michael, 2026-09-14: *"the model is only as good as the two seconds it
/// takes to use in a truck."* Two rules follow from that:
///
/// 1. **The attached date defaults to today.** Editable, but nobody types it.
/// 2. **If the animal is already wearing a collar, that collar is recorded as
///    removed on the same day** — the recapture case, which is the ordinary
///    one.
/// 3. **A same-day swap may carry a time, prefilled with now** (design §4a,
///    task 11.251). Michael, 2026-09-15: *"If asking for a time of the swap
///    is needed to get around this issue so be it."* The time is what says
///    which animal a bearing taken that afternoon was about; without it the
///    day is inside two deployments and reported as contested. See
///    [LinkPlan.isSwap] for when it is offered and [LinkPlan.at] for what it
///    writes.
///
/// ## Why this is a plan and then a write, rather than one method
///
/// **Rule 2 writes to a row the person did not touch**, and §5a is explicit
/// that this is why the confirmation exists: *"silently amending a second
/// record is how a field note becomes wrong without anybody making a
/// mistake."*
///
/// So [plan] reads the project and returns exactly what would happen; the
/// screen turns that into a sentence naming both collars and both dates; and
/// [apply] writes precisely the plan it was shown. **The confirmation and the
/// write cannot disagree, because they are the same object** — a sentence
/// composed separately from the write is a sentence that goes stale the first
/// time either changes.
///
/// ## The handover is an overlap of nothing, because it carries a time
///
/// The closing deployment's `removed_date` and the new one's `attached_date`
/// are the **same instant** — the swap time the confirmation stamps on both
/// ([LinkPlan.at]) — and an instant has no width to share. **The interlock
/// therefore never fires on the ordinary case**, which is what makes it a
/// guard rather than an obstacle, and `deployment_linking_test.dart` watches
/// that pass as well as watching a real conflict refused. A guard that blocks
/// the ordinary case is worse than no guard.
///
/// Until task 11.263 the two ends were bare days and the handover was let
/// through by §6's one-day allowance. That allowance is withdrawn (§6a): two
/// bare days on one date both cover the whole of it, and the interlock now
/// reads them that way and refuses. **So a plan for a swap must be stamped
/// with a time before it is applied** — [apply] with a date-only swap plan
/// is refused by the interlock, not silently adjusted, and the confirmation
/// dialog is what stamps it.
class DeploymentLinking {
  DeploymentLinking(this.database);

  final Database database;

  static const _uuid = Uuid();

  /// What linking [tagId] to [individualId] on [attachedDate] would do.
  ///
  /// Reads; writes nothing. Throws [ArgumentError] when either end is not a
  /// live row of [projectId] — both are screen mistakes rather than states
  /// the database can be in afterwards.
  ///
  /// [attachedDate] is a day here — the screen passes `deploymentDateFor(now)`
  /// — and the plan comes back date-only. Whether it *stays* date-only is
  /// the confirmation's decision: see [LinkPlan.isSwap] and [LinkPlan.at].
  Future<LinkPlan> plan({
    required String projectId,
    required String tagId,
    required String individualId,
    required DateTime attachedDate,
    String? timeZone,
  }) async {
    final deployments = DeploymentRepository(database);
    // Task 11.331: the new row's days are the project's zone's. A caller
    // that already resolved it (the screen that computed [attachedDate]'s
    // "today" in it) passes it; otherwise it is read here, the same way.
    final zone = timeZone ?? await _projectZone(projectId);
    final individual = await IndividualRepository(
      database,
    ).findById(individualId, projectId: projectId);
    if (individual == null) {
      throw ArgumentError('no live individual $individualId in $projectId');
    }
    final hers = await deployments.findByIndividual(
      individualId,
      projectId: projectId,
    );
    final its = await deployments.findByTag(tagId, projectId: projectId);
    final closing = _deploymentToClose(hers);
    return LinkPlan(
      projectId: projectId,
      tagId: tagId,
      individualId: individualId,
      attachedDate: attachedDate,
      closing: closing,
      closingDate: _inZoneOf(closing, attachedDate, zone),
      cameOffToday: _departureOn(its, attachedDate, zone),
      herLastCameOffToday: _departureOn(hers, attachedDate, zone),
      timeZone: zone,
    );
  }

  Future<String?> _projectZone(String projectId) async {
    final project = await ProjectRepository(database).findById(projectId);
    return project == null ? null : effectiveProjectTimeZone(project);
  }

  /// [value] — a bare day in [zone], or an instant — as the closing row
  /// [closing] should store it (task 11.331). An instant is the same instant
  /// everywhere. **A bare day is moved to the same calendar date in the
  /// closing row's own zone**, because that row keeps the zone it was written
  /// in: written raw, a Denver midnight in an Arizona row would read there as
  /// a time at 23:00 the day before.
  static DateTime _inZoneOf(Deployment? closing, DateTime value, String? zone) {
    if (closing == null || deploymentEndHasTime(value, zone)) return value;
    return fieldDayStart(fieldCalendarDate(value, zone), closing.timeZone);
  }

  /// A deployment among [its] — or among an animal's — that ended on [day]:
  /// the other half of a same-day swap, the one this link does *not* write.
  ///
  /// Michael's case, 2026-09-15: tag 2 comes off Kea this morning (a removed
  /// date, set on Kea's screen) and goes onto Marie this afternoon (this
  /// link). The removal is a row somebody already wrote and §5a leaves it
  /// alone; it is found here only so the confirmation knows this is a swap
  /// and offers the time — without it, every one of tag 2's bearings today
  /// would be contested between Kea and Marie.
  ///
  /// Asked of the *animal's* deployments too since task 11.263
  /// ([LinkPlan.herLastCameOffToday]): tag 1 comes off Kea this morning on
  /// her own screen, and tag 2 goes on this afternoon through this link.
  /// With the one-day allowance gone, a bare-day attach today would overlap
  /// the morning's deployment — from midnight to the moment tag 1 came off
  /// — and be refused; a time on the link is what makes it a handover.
  static Deployment? _departureOn(
    Iterable<Deployment> its,
    DateTime day,
    String? zone,
  ) {
    // The field day [day] names, compared with each removal's own field day
    // — calendar dates, because the two rows may have been written in
    // different zones (task 11.331).
    final theDay = fieldCalendarDate(day, zone);
    for (final d in its) {
      if (d.sync.isDeleted) continue;
      final removed = d.removedDate;
      if (removed == null) continue;
      if (d.calendarDateOf(removed) == theDay) return d;
    }
    return null;
  }

  /// The animal's deployment that the new one displaces, or null.
  ///
  /// **Two edges §5a leaves to the task, decided here and asserted:**
  ///
  /// - **A deployment that already carries a removed date is left alone.**
  ///   Somebody has already said when that collar came off; overwriting it
  ///   with today would be the app correcting a field note nobody said was
  ///   wrong.
  /// - **A deployment with no attached date is not silently given one**, and
  ///   it is not closed either. It covers no interval, so it conflicts with
  ///   nothing and displaces nothing — closing it would invent the fact that
  ///   it ended, on top of the fact nobody recorded that it began.
  ///
  /// At most one survives both filters, because the interlock has already
  /// guaranteed the animal has at most one open deployment — so returning the
  /// first is that guarantee read rather than re-derived. A second could only
  /// arrive from a device that broke the rule; closing the earliest is the
  /// harmless answer, and the interlock then refuses the link and names the
  /// one still open, which is the right way round.
  static Deployment? _deploymentToClose(Iterable<Deployment> hers) {
    for (final d in hers) {
      if (d.attachedDate == null) continue;
      if (d.removedDate != null) continue;
      return d;
    }
    return null;
  }

  /// Writes [plan] — the new deployment, and the closing of the old one if
  /// there is one — **in one transaction**.
  ///
  /// Atomic because half of it is worse than none: closing the old collar and
  /// then failing to open the new one leaves the animal wearing nothing, on a
  /// day when it is wearing something.
  ///
  /// Throws [OverlappingDeployment] if the interlock refuses, which rolls the
  /// whole thing back. Throws [UnauthorizedMutation] for a viewer.
  ///
  /// **[adding] puts the tag on the project first, in the same transaction**
  /// — task 11.321's one-step link. Michael, 2026-09-30: linking took three
  /// places (the Tag Library, the project, the animal). A Tag Library tag is
  /// copied in through [TagRepository.copyFromLibrary], the same path More →
  /// Tags's "Copy from library" uses; a new tag is created through
  /// [TagRepository.insert]. Either way its id is [LinkPlan.tagId]. A refused
  /// link takes the new tag with it, so the person is never left with a tag
  /// on the project they did not get the link for.
  Future<Deployment> apply(
    LinkPlan plan, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
    TagToAdd? adding,
  }) async {
    final at = now ?? DateTime.now();
    final sync = SyncMeta.initial(
      now: at,
      modifiedBy: actor.userId,
      originDeviceId: deviceId,
    );
    final created = Deployment(
      deploymentId: _uuid.v4(),
      projectId: plan.projectId,
      tagId: plan.tagId,
      individualId: plan.individualId,
      attachedDate: plan.attachedDate,
      sync: sync,
      timeZone: plan.timeZone,
    );
    await database.transaction((txn) async {
      final deployments = DeploymentRepository(txn);
      switch (adding) {
        case null:
          break;
        case LibraryTagToAdd(:final entry):
          // A person's act, never replication: the copy is stamped as theirs.
          final userId = actor.userId;
          if (userId == null) {
            throw ArgumentError('copying a tag in needs a person to stamp it');
          }
          await TagRepository(txn).copyFromLibrary(
            entry,
            projectId: plan.projectId,
            tagId: plan.tagId,
            modifiedBy: userId,
            deviceId: deviceId,
            now: at,
          );
        case NewTagToAdd(:final tag):
          if (tag.tagId != plan.tagId || tag.projectId != plan.projectId) {
            throw ArgumentError('the new tag is not the one the plan links');
          }
          await TagRepository(txn).insert(tag);
      }
      // **The old collar comes off first.** Not for atomicity — the
      // transaction handles that — but because the interlock is asked about
      // the state it finds: with the old one still open, the new one
      // overlaps it by an unbounded period and would be refused. Closing
      // first, at the same instant the new one opens, is what turns the
      // recapture into a handover that overlaps by nothing.
      final closing = plan.closing;
      if (closing != null) {
        await deployments.update(
          closing.copyWith(removedDate: plan.closingDate),
          actor: actor,
          deviceId: deviceId,
          now: at,
        );
      }
      await deployments.link(created);
    });
    DataArrival.announce();
    return created;
  }

  /// **The same-individual neighbour that makes a handover undecidable from
  /// one row's own editor** — task 11.270, the limit design §6b records and
  /// does not resolve on its own.
  ///
  /// Michael's arithmetic, worked through rather than guessed: date collar
  /// 1's removal to a day nothing else is on and no time is offered, because
  /// nothing conflicts yet — a bare day claims the whole of itself. Attach
  /// (or correct) collar 2 to that same day and the interlock refuses it;
  /// [DeploymentLinking._setAttached]'s and `_setRemoved`'s own single-time
  /// offer (task 11.265) cannot escape it either, because a time on only
  /// *one* end still leaves the other's bare day claiming the whole 24
  /// hours. Each control is correct and the pair cannot converge alone.
  ///
  /// [edited] is the row a person is correcting to [day]; [editingAttached]
  /// says which end that is — `true` when its attached date is being set,
  /// `false` when its removed date is. The neighbour this looks for is a
  /// different, live deployment of the same animal whose **opposite** end is
  /// a bare day equal to [day] itself.
  ///
  /// Null when there is no such neighbour — including when one exists but
  /// already carries a time, which the single-time offer already resolves.
  static Deployment? bareDayHandoverPartner(
    Iterable<Deployment> allDeployments, {
    required Deployment edited,
    required bool editingAttached,
    required DateTime day,
  }) {
    // [day] is a day of [edited]'s; each candidate's boundary is read in its
    // own row's zone, and the two compared as calendar dates (task 11.331).
    final theDay = edited.calendarDateOf(day);
    for (final other in allDeployments) {
      if (other.sync.isDeleted) continue;
      if (other.deploymentId == edited.deploymentId) continue;
      if (other.individualId != edited.individualId) continue;
      final boundary = editingAttached ? other.removedDate : other.attachedDate;
      if (boundary == null) continue;
      if (other.endHasTime(boundary)) continue;
      if (other.calendarDateOf(boundary) != theDay) continue;
      return other;
    }
    return null;
  }

  /// **Writes both ends of a bare-day handover in one transaction** — the
  /// fix [bareDayHandoverPartner] finds the need for. The outgoing collar's
  /// removed date and the incoming collar's attached date are stamped with
  /// the *same* instant, so the pair overlaps by nothing (§6a).
  ///
  /// **Why this cannot be [apply]'s "closing first" shape.** There, only one
  /// side pre-exists — the other is a brand-new row not yet in the table —
  /// so closing the old one first leaves nothing stale for the insert to
  /// conflict with. Here **both rows already exist**, each still carrying
  /// its own wrong bare day, and each already overlaps the *other's* stale
  /// value: writing either one first, checked the ordinary way, would ask
  /// the interlock about the row just written against the row not yet
  /// written — which is the deadlock this method exists to escape, moved
  /// one step later rather than closed. So the interlock is asked **once**,
  /// with both rows already at their final values, before either is
  /// written — through [DeploymentRepository.updateByKey], the same
  /// lower-level write [DeploymentRepository.update] uses beneath its own
  /// check, which this method supplies for itself instead.
  ///
  /// Throws [OverlappingDeployment] — naming whichever end still conflicts
  /// with something else, a third row not party to this handover — before
  /// either write happens, so **a refusal applies neither row.**
  Future<void> applyHandover(
    HandoverPlan plan, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final finalOutgoing = plan.outgoing.copyWith(removedDate: plan.instant);
    final finalIncoming = plan.incoming.copyWith(attachedDate: plan.instant);
    await database.transaction((txn) async {
      final deployments = DeploymentRepository(txn);
      final others = (await deployments.findByProject(plan.outgoing.projectId))
          .where(
            (d) =>
                d.deploymentId != plan.outgoing.deploymentId &&
                d.deploymentId != plan.incoming.deploymentId,
          )
          .map((d) => d.interval)
          .toList();
      final outgoingConflict = DeploymentInterlock.conflictFor(
        finalOutgoing.interval,
        [...others, finalIncoming.interval],
      );
      if (outgoingConflict != null) {
        throw OverlappingDeployment(
          candidate: finalOutgoing,
          conflict: outgoingConflict,
        );
      }
      final incomingConflict = DeploymentInterlock.conflictFor(
        finalIncoming.interval,
        [...others, finalOutgoing.interval],
      );
      if (incomingConflict != null) {
        throw OverlappingDeployment(
          candidate: finalIncoming,
          conflict: incomingConflict,
        );
      }
      await deployments.updateByKey(
        {
          'deployment_id': finalOutgoing.deploymentId,
          'project_id': finalOutgoing.projectId,
        },
        finalOutgoing.toColumns(),
        actor: actor,
        deviceId: deviceId,
        now: at,
      );
      await deployments.updateByKey(
        {
          'deployment_id': finalIncoming.deploymentId,
          'project_id': finalIncoming.projectId,
        },
        finalIncoming.toColumns(),
        actor: actor,
        deviceId: deviceId,
        now: at,
      );
    });
    DataArrival.announce();
  }

  /// **Deletes an animal, after withdrawing every link it has** — task
  /// 11.244, and the withdrawal of task 11.241's *"there is no delete
  /// animal"*.
  ///
  /// 11.241 refused a bare delete because the only way to make one then was
  /// the merge, and deleting instead would have manufactured collars with no
  /// animal — a question for a person. **With tags entered as inventory that
  /// reasoning is gone**: a collar with no animal is the ordinary state of a
  /// transmitter on a shelf (§1), so an animal somebody created by mistake is
  /// an ordinary thing to remove. The v16 backfill also left real ones on
  /// Michael's phone.
  ///
  /// **Every deployment is withdrawn, not closed.** A withdrawn link says the
  /// collar was never on this animal; a removed date says it was and came
  /// off. Deleting the animal means the first — there is no animal for it to
  /// have been on.
  ///
  /// **No bearing moves.** They are keyed by collar, and the collars are
  /// untouched. Returns how many links were withdrawn.
  ///
  /// **Owner-only since task 11.255, and refused before the first write.** A
  /// contributor refused this must not be left having silently withdrawn
  /// every collar first — `IndividualRepository.remove` asserts the same
  /// rung, but asking here too, before any deployment is touched, is what
  /// keeps a refused delete from being a half-applied one. See the reasoning
  /// on [IndividualRepository.assertMayDelete].
  Future<int> deleteAnimal({
    required String projectId,
    required String individualId,
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    await IndividualRepository(database).assertMayDelete(projectId, actor);
    final withdrawn = await database.transaction((txn) async {
      final deployments = DeploymentRepository(txn);
      final hers = await deployments.findByIndividual(
        individualId,
        projectId: projectId,
      );
      for (final d in hers) {
        await deployments.unlink(
          d.deploymentId,
          projectId: projectId,
          actor: actor,
          deviceId: deviceId,
          now: at,
        );
      }
      await IndividualRepository(txn).remove(
        individualId,
        projectId: projectId,
        actor: actor,
        deviceId: deviceId,
        now: at,
      );
      return hers.length;
    });
    DataArrival.announce();
    return withdrawn;
  }
}

/// **A tag that is not on the project yet, to put there as it is linked** —
/// task 11.321. See [DeploymentLinking.apply]'s `adding`.
sealed class TagToAdd {
  const TagToAdd();
}

/// A Tag Library tag, copied into the project under the plan's tag id.
final class LibraryTagToAdd extends TagToAdd {
  const LibraryTagToAdd(this.entry);
  final TagLibraryEntry entry;
}

/// A tag created on the project. Its id and project must be the plan's.
final class NewTagToAdd extends TagToAdd {
  const NewTagToAdd(this.tag);
  final Tag tag;
}

/// What linking a collar to an animal is about to do — both halves of it.
///
/// Handed to the confirmation and then to the write, so the sentence a person
/// reads and the rows that land are the same decision. See
/// [DeploymentLinking].
class LinkPlan {
  const LinkPlan({
    required this.projectId,
    required this.tagId,
    required this.individualId,
    required this.attachedDate,
    required this.closing,
    required this.closingDate,
    this.cameOffToday,
    this.herLastCameOffToday,
    this.timeZone,
  });

  final String projectId;
  final String tagId;
  final String individualId;

  /// When the new collar goes on. Defaults to today at the call site; the
  /// person may change it before confirming.
  final DateTime attachedDate;

  /// The animal's current deployment, which this link displaces — or null
  /// when she is wearing nothing. **This is the row the person did not
  /// touch**, and the reason §5a asks before writing.
  final Deployment? closing;

  /// The instant [closing] will be recorded as removed. The same instant the
  /// new collar goes on — which is what makes the handover overlap by
  /// nothing, and is why [at] stamps both ends together.
  final DateTime closingDate;

  /// The collar's own deployment that ended the same day — on another
  /// animal, in every case that matters — see [DeploymentLinking._departureOn].
  /// Read, never written, by this plan.
  final Deployment? cameOffToday;

  /// The animal's own deployment that ended the same day — her previous
  /// collar, already recorded as off on her screen before this link (task
  /// 11.263). Read, never written, by this plan; see
  /// [DeploymentLinking._departureOn].
  final Deployment? herLastCameOffToday;

  /// The zone the new row's days are written in — the project's at the
  /// moment of the link (task 11.331). The new row stores it.
  final String? timeZone;

  /// Whether this link amends a record the person did not open.
  bool get amendsAnotherRow => closing != null;

  /// **Whether this link is a same-day swap** — design §4a's rule 2 — and so
  /// the confirmation offers a time.
  ///
  /// Three shapes, and any is enough: the animal is already wearing a
  /// collar that comes off as this one goes on ([closing]); this collar came
  /// off another animal today ([cameOffToday]); or the animal's previous
  /// collar came off earlier today ([herLastCameOffToday], task 11.263). In
  /// each, some moment today is inside two deployments unless a time says
  /// which — and since the interlock tolerates no overlap, a bare day here
  /// would not merely be contested, it would be refused.
  ///
  /// **A link that is not a swap stays date-only, on purpose.** A collar
  /// from the shelf onto a bare animal has no other deployment to disagree
  /// with, and a time there could only *lose* bearings: the bird was
  /// collared at 9 a.m. in the field and the link tapped at 2 p.m. at the
  /// truck, and a start of 2 p.m. would hand the morning's bearings to
  /// nobody. The date is the honest value where there is nothing to split.
  bool get isSwap =>
      closing != null || cameOffToday != null || herLastCameOffToday != null;

  /// This plan with both ends at [instant] — the time the person accepted on
  /// a swap. **The same instant closes the outgoing deployment and opens the
  /// incoming one**, so the two can never disagree; `Deployment.coversMoment`
  /// then hands a bearing before it to the old collar and one after it to
  /// the new, with nothing left contested.
  ///
  /// [instant] is expected to fall on [attachedDate]'s day; a screen that
  /// let the day and the time drift apart would be writing a date nobody
  /// confirmed.
  LinkPlan at(DateTime instant) => LinkPlan(
    projectId: projectId,
    tagId: tagId,
    individualId: individualId,
    attachedDate: instant,
    closing: closing,
    closingDate: instant,
    cameOffToday: cameOffToday,
    herLastCameOffToday: herLastCameOffToday,
    timeZone: timeZone,
  );
}

/// **What a past-day handover between two never-timed rows is about to
/// write** — task 11.270, §5a's shape reused for the case it does not reach.
///
/// Handed to the confirmation and then to [DeploymentLinking.applyHandover],
/// the same way [LinkPlan] is: the sentence a person reads and the rows that
/// land are the same object, so they cannot disagree.
class HandoverPlan {
  const HandoverPlan({
    required this.outgoing,
    required this.incoming,
    required this.instant,
  });

  /// The collar coming off. Its `removed_date` is what [instant] writes.
  final Deployment outgoing;

  /// The collar going on. Its `attached_date` is what [instant] writes.
  final Deployment incoming;

  /// The shared moment that closes [outgoing] and opens [incoming] — the
  /// same instant on both, so the pair can never overlap (§6a).
  final DateTime instant;
}

/// **The sentence a person reads before a past-day handover writes both
/// rows** — task 11.270. [outgoingTagName] and [incomingTagName] name the
/// two collars; both are stamped with [instant] and neither is written until
/// this is confirmed.
String handoverConfirmationText({
  required String animalName,
  required String outgoingTagName,
  required String incomingTagName,
  required DateTime instant,
  String? timeZone,
}) {
  final at = formatLinkInstant(instant, timeZone);
  return '$animalName\'s $outgoingTagName will be recorded as removed $at, '
      'and $incomingTagName as attached the same moment. Neither is written '
      'until you confirm.';
}

/// **The sentence a person reads before a link happens** — §5a's wording,
/// naming the tags and the dates.
///
/// Shared by the dialog that asks and by the test that holds it, the way
/// `mergeConfirmationText` is: a sentence composed at the call site is a
/// sentence no test can hold to the rule it is about.
///
/// **Not trimmed to a yes/no**, and §5a says why: this writes to a row the
/// person did not touch. [closingTagName] is the collar that comes off, and
/// its clause is the whole point of the sentence — when there is none, the
/// sentence is one line, because there is nothing unexpected to warn about.
String linkConfirmationText({
  required String tagName,
  required String animalName,
  required DateTime attachedDate,
  String? closingTagName,
  DateTime? closingDate,
  String? timeZone,
  String? closingTimeZone,
}) {
  final attached = formatLinkInstant(attachedDate, timeZone);
  final first = 'Link $tagName to $animalName, attached $attached.';
  if (closingTagName == null || closingDate == null) return first;
  return '$first\n\n$animalName\'s $closingTagName will be recorded as '
      'removed ${formatLinkInstant(closingDate, closingTimeZone)}. That is a '
      'change to a record you did not open.';
}

/// [formatLinkDate], plus the time of day when the value carries one:
/// `2026-09-14 14:32`. A date-only deployment end reads exactly as it did
/// before task 11.251, so the row somebody has been looking at all season
/// does not change under them; a swap time shows because it is a fact that
/// decides which animal an afternoon's bearings belong to, and a value that
/// decides something is shown (Michael's rule — the word is the answer).
String formatLinkInstant(DateTime value, [String? zone]) {
  if (!deploymentEndHasTime(value, zone)) return formatLinkDate(value, zone);
  final local = fieldWallClock(value, zone);
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${formatLinkDate(value, zone)} $hour:$minute';
}

/// A date as the confirmation and the collar rows write it: `2026-09-14`.
///
/// **ISO, not a localised format**, for the reason the rest of this app
/// writes dates that way: a field record read in another country must not
/// depend on which of the day and the month a reader assumes comes first.
///
/// **Rendered in the device's own zone**, which is the half that pairs with
/// [deploymentDateFor] — see there for what a deployment date is and what it
/// costs.
String formatLinkDate(DateTime date, [String? zone]) {
  final local = fieldCalendarDate(date, zone);
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// **How many of [tagBearingTimes] change animal because [deployment]'s
/// removed date is about to move to [newRemoved]** — task 11.261.
///
/// A bearing's animal is derived from time (design §2, `coversMoment`), so
/// moving a removal from 09:00 to 15:00 re-attributes every bearing in
/// between — which is the point, not a side effect. This counts them by
/// comparing [deployment] against the same row with the new end, rather than
/// reasoning about the interval by hand, so the count and the write can never
/// disagree about what "in between" means.
///
/// Named on screen before the write happens, the way §5a names the second
/// record a link touches — this is the same rule applied to a record the
/// person opened themselves rather than one they did not.
int countReattributedBearings({
  required Deployment deployment,
  required DateTime? newRemoved,
  required Iterable<DateTime> tagBearingTimes,
}) {
  final after = deployment.copyWith(removedDate: newRemoved);
  var count = 0;
  for (final at in tagBearingTimes) {
    if (deployment.coversMoment(at) != after.coversMoment(at)) count++;
  }
  return count;
}

/// **What a back-dated link does to bearings already taken** — task 11.322.
///
/// A bearing's animal is worked out from time, so dating a link before today
/// changes the answer for every bearing in between, exactly as moving a removal
/// does ([countReattributedBearings]). Two groups move, and a link can move
/// both:
///
/// - [credited]: bearings on the **new** tag that now fall inside the new
///   deployment, which belonged to no animal until now (a bearing that
///   belonged to another animal would have been refused by the interlock).
/// - [uncredited]: bearings on the **old** tag, the one this link takes off the
///   animal, that fall after it comes off and so stop being hers.
///
/// Asked of the same `coversMoment` the rest of the app asks, so the count and
/// the write cannot disagree about what "in between" means.
({int credited, int uncredited}) countLinkReattributions({
  required LinkPlan plan,
  required Iterable<DateTime> newTagBearingTimes,
  required Iterable<DateTime> closingTagBearingTimes,
}) {
  final incoming = Deployment(
    deploymentId: 'counting-only',
    projectId: plan.projectId,
    tagId: plan.tagId,
    individualId: plan.individualId,
    attachedDate: plan.attachedDate,
    sync: SyncMeta.initial(now: plan.attachedDate, modifiedBy: 'counting-only'),
    timeZone: plan.timeZone,
  );
  final credited = newTagBearingTimes.where(incoming.coversMoment).length;
  final closing = plan.closing;
  final uncredited = closing == null
      ? 0
      : countReattributedBearings(
          deployment: closing,
          newRemoved: plan.closingDate,
          tagBearingTimes: closingTagBearingTimes,
        );
  return (credited: credited, uncredited: uncredited);
}

/// **The one place a deployment's removed date or time is written** — task
/// 11.261. `_DeploymentRow`'s editor on the animal's own screen and the
/// Record screen's same-day-handover prompt (task 11.260) both call this
/// rather than each keeping its own `repo.update`/catch pair, which is the
/// two-writers shape this project keeps paying for (CLAUDE.md).
///
/// **Why a shared write rather than routing the prompt to the editor.** The
/// Record screen is a field screen — a round trip to More → Animals
/// mid-bearing to correct a swap time would cost more than the duplication
/// it avoids. Sharing the write keeps one set of refusals without asking the
/// person to leave what they were doing.
///
/// Returns null on success, or the sentence to show in a SnackBar — never
/// throws, so neither caller needs its own catch block.
Future<String?> writeRemovedDate({
  required DeploymentRepository repo,
  required Deployment deployment,
  required DateTime? removed,
  required MutationActor actor,
  String? deviceId,
}) async {
  try {
    await repo.update(
      deployment.copyWith(removedDate: removed),
      actor: actor,
      deviceId: deviceId,
    );
  } on OverlappingDeployment catch (e) {
    return e.message;
  } on UnauthorizedMutation catch (e) {
    return e.refusalSentence(
      asViewer:
          'Viewers cannot change a tag record — ask an owner to change '
          'your role.',
    );
  }
  return null;
}

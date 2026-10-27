import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tritrack_sync/tritrack_sync.dart'
    show DeploymentInterlock, DeploymentInterval;

import '../../data/models/deployment.dart';
import '../../data/repositories/repository_providers.dart';

/// **Which collar is on which animal in one project, and when** — task
/// 11.243. Live rows only, oldest first.
///
/// The list every screen that has to draw a collar beside an animal reads.
/// It is on the **same refresh list as the project's tags and animals**
/// (`refreshTagViews`), because the three move together by construction: a
/// deployment names one of each, and a screen that saw a new link but not the
/// animal it names — or the animal but not the link — would be showing a
/// grouping that is not true.
///
/// `autoDispose`, like every family on that list, for the reason
/// `refresh_lists_test.dart` gives: a keepAlive family invalidated mid-build
/// hangs a screen for good, an autoDispose one throws loudly and rebuilds.
final projectDeploymentsProvider =
    FutureProvider.autoDispose.family<List<Deployment>, String>((
      ref,
      projectId,
    ) async {
      final repo = await ref.watch(deploymentRepositoryProvider.future);
      return repo.findByProject(projectId);
    }, name: 'projectDeploymentsProvider');

/// **Which collars a link on [date] would be refused for** — what "Link a
/// tag" must not offer (task 11.244).
///
/// A collar already covered by a live deployment on that day would be refused
/// by the interlock a moment after it was offered. Filtering it out of the
/// picker is a pre-check **more permissive than nothing and never stricter
/// than the write**: it hides no collar a person could actually link, it only
/// spares them a refusal they could not have avoided.
///
/// ## It asks the interlock's own arithmetic, not a second rule
///
/// Until task 11.251 this read `Deployment.covers(date)` — half-open, so a
/// collar taken off today was free today, which is what let Michael move a
/// collar between two animals in one day. When §4a closed a date-only day at
/// both ends, that reading would have hidden the collar on the one day it is
/// most likely to be linked. Rather than write a third notion of "busy", the
/// picker asks exactly what the write will ask: would the deployment the
/// link would write overlap this one at all (`DeploymentInterlock.overlaps`,
/// task 11.263)? So a collar removed *yesterday* is free, one still on is
/// busy, and **the picker cannot disagree with the write because it is the
/// write's arithmetic.** The animal's side is deliberately not asked — her
/// own open collar is the one §5a closes in the same act.
///
/// **What the link would write depends on the collar's own day** — the same
/// rule `LinkPlan.isSwap` applies. A collar that came off *today* makes the
/// link a same-day swap, and the confirmation stamps it with the instant
/// [at] (design §4a rule 2); any other collar gets a bare day. So the probe
/// here is the instant for a collar whose removal falls on [at]'s day, and
/// the bare day otherwise — a probe that used the bare day for both would
/// be **stricter than the write** on exactly the collar Michael moves, and
/// hide it on the one day it is most likely to be linked.
///
/// Two consequences worth stating, both design §6a:
///
/// - **A collar removed today with a time is free once that time has
///   passed** — the swap the link writes starts at [at], after the removal.
///   Before the removal's time it is busy, and the write would refuse it
///   too.
/// - **A collar removed today as a bare day is busy all day.** Its removal
///   covers the whole of today, and a swap at [at] shares the rest of it.
///   The way to link it today is a time on the removal (the animal's own
///   screen, *Edit removed date* → *Set a time*). Recorded here because it
///   is the one case where a collar that has been taken off is not offered,
///   and a reader meeting it will take it for a defect; it is the rule — a
///   same-day handover requires a time.
///
/// A deployment with no attached date covers no interval, so the collar it
/// names is *not* busy — the same answer the interlock gives about it.
///
/// [zone] is the project's — the zone the link would write its day in (task
/// 11.331); each existing row's removal day is read in its own zone.
Set<String> tagIdsOnAnAnimalAt(
  List<Deployment> deployments,
  DateTime at, {
  String? zone,
}) {
  final day = deploymentDateFor(at, zone);
  return {
    for (final d in deployments)
      if (!d.sync.isDeleted && _wouldBeRefused(d, at: at, day: day, zone: zone))
        d.tagId,
  };
}

bool _wouldBeRefused(
  Deployment d, {
  required DateTime at,
  required DateTime day,
  required String? zone,
}) {
  if (d.attachedDate == null) return false;
  final removed = d.removedDate;
  final cameOffToday =
      removed != null &&
      d.calendarDateOf(removed) == fieldCalendarDate(at, zone);
  return DeploymentInterlock.overlaps(
    DeploymentInterval(
      deploymentId: '',
      tagId: d.tagId,
      individualId: '',
      attachedDate: cameOffToday ? at : day,
      timeZone: zone,
    ),
    d.interval,
  );
}

/// **Which collars can be heard at [at]** — what the Record screen offers
/// (task 11.249, narrowed to the moment by task 11.260).
///
/// Michael, on his phone, 2026-09-14: both collars he had linked to one animal
/// were on the wheel, though one had been taken off a month earlier. Design
/// §4 already decides this — a deployment has dates, and the collar on an
/// animal *now* is the one whose interval contains this instant — so the
/// wheel lists a collar only while some live deployment says it is on
/// something.
///
/// ## The rule asks [Deployment.coversMoment], not the day question anymore
///
/// **Task 11.249 wrote this against a day-granular `spansDay` method**,
/// since deleted — a collar was offered for the whole calendar day either
/// end of its deployment falls in, on Michael's 2026-09-14 ruling that a
/// handover day should show both
/// collars. **That was right while a deployment knew only calendar days.**
/// Task 11.251 gave a same-day swap a *time*, and the Log's filter, the
/// Map's filter and the Map's colour all moved to asking
/// [Deployment.coversMoment] — the moment question, not the day question.
/// The wheel did not, and Michael found it on 2026-09-16: *"Taken off at
/// 9 am but their bearing is at 11 am but on the old tag. Wouldn't the old
/// tag be with me not the animal?"* Yes — a bearing on a collar after it
/// comes off is a bearing on the collar in somebody's bag, not one worth
/// keeping the collar on the wheel for. **So this asks `coversMoment` now,
/// same as every other reader — `spansDay` is deleted rather than kept
/// beside it with no caller**, since a model method nothing reads is exactly
/// the kind of stale fact this project's rules warn about. Nothing is lost
/// for the *date-only* case, which is unchanged: `coversMoment` reads a
/// date-only end as covering the whole of both its end days, the same answer
/// `spansDay` gave (design §4a rule 1). The two only ever disagreed once an
/// end carried a time, which is design §4a rule 2's case — the boundaries
/// are asserted in `tag_ids_audible_on_test.dart`.
///
/// - **Removed today, with no time on it, is still offered all day.** A
///   date-only end covers the whole of its day under `coversMoment`, and a
///   bearing taken that afternoon is a real bearing on a real collar. Since
///   task 11.263 this cannot put two collars of one animal on the wheel at
///   once from this app's own writes — a same-day handover needs a time,
///   and the interlock refuses the bare-day pair — so it is simply the
///   collar that came off today, offered until midnight.
/// - **Removed at a specific time is offered only until that instant.** The
///   collar leaves the wheel the moment the swap is confirmed and the new
///   one appears — no day-long grace either side.
/// - **A collar with no deployment at all is not offered.** That is equipment
///   in the box (design §1), and offering it would be the defect this rule
///   exists to close, with a different date. Decided in the plan rather than
///   left to fall out of the implementation; the Record screen's quick-add
///   puts a new collar on an animal in the same act for exactly this reason.
/// - **A deployment with no attached date covers no moment**, the same
///   answer [tagIdsOnAnAnimalAt] and `DeploymentInterlock` give about it.
///   Nobody said when the collar went on, so nothing can say it is on now.
///
/// **Two collars for one animal at once can still be on the wheel** — from a
/// row written by a build with the one-day allowance, or a pair written in
/// another zone — and the wheel lists both without comment. Tasks 11.260 and
/// 11.262 built a prompt and a chooser above the wheel to explain that state
/// and offer to fix it; **task 11.263 deleted both**, because the state they
/// described can no longer be created here (design §6a) and a control that
/// only ever fires on legacy data is machinery serving nothing. The Map and
/// the Log render such a moment as *contested*, which is enough for anything
/// historical.
Set<String> tagIdsAudibleOn(List<Deployment> deployments, DateTime at) => {
  for (final d in deployments)
    if (!d.sync.isDeleted && d.coversMoment(at)) d.tagId,
};

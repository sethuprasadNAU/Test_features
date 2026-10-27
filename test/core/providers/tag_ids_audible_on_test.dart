import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/data/models/deployment.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack_sync/tritrack_sync.dart'
    show DeploymentInterlock, DeploymentInterval;

import '../../data/fixtures.dart';

/// **Task 11.249 — which collars the Record screen offers, at its two
/// boundaries — narrowed to the moment by task 11.260.**
///
/// Michael linked two collars to one animal in turn and both were on the
/// wheel, though one had come off a month earlier. The rule is
/// `tagIdsAudibleOn`: a collar is offered at a moment only while a
/// deployment with an attached date says it is on an animal then. Most of
/// the tests below use date-only deployments — the ordinary case — where
/// **counting the day it comes off** still holds exactly as task 11.249
/// wrote it: design §4a rule 1 gives a date-only end the whole of both its
/// end days. The one boundary that changed is a *timed* removal, asserted
/// in the last group — task 11.260 moved `tagIdsAudibleOn` from
/// `Deployment.spansDay` (deleted) to `Deployment.coversMoment`, so a
/// collar removed at a specific time now leaves the wheel at that instant
/// rather than at the end of the day.
void main() {
  final today = DateTime(2026, 9, 14, 10, 30); // a Monday morning, local
  final yesterday = DateTime(2026, 9, 13);
  final lastMonth = DateTime(2026, 8, 14);

  Deployment dep({
    required String id,
    required String tagId,
    String individualId = 'individual-1',
    DateTime? attached,
    bool noAttachedDate = false,
    DateTime? removed,
    bool deleted = false,
  }) {
    final d = sampleDeployment(
      id: id,
      tagId: tagId,
      individualId: individualId,
      attachedDate: attached,
      noAttachedDate: noAttachedDate,
      removedDate: removed,
    );
    if (!deleted) return d;
    return d.copyWith(
      sync: SyncMeta.initial(now: today).copyWith(deletedAt: today),
    );
  }

  test('a collar taken off last month is not offered — the defect Michael saw',
      () {
    final offered = tagIdsAudibleOn([
      dep(id: 'old', tagId: 'tag-old', attached: DateTime(2026, 1, 1), removed: lastMonth),
      dep(id: 'new', tagId: 'tag-new', attached: lastMonth),
    ], today);
    expect(offered, {'tag-new'},
        reason: 'the animal wears one collar today; the wheel must not list '
            'the one that came off in August');
  });

  test('a collar with no deployment at all is not offered — equipment in the box',
      () {
    // Nothing names `tag-boxed`. The decision is in the plan rather than in
    // the implementation: a collar nobody has put on anything is not audible
    // by anybody's account, and the Record screen's quick-add is the route
    // that makes a new collar offered — it links it in the same act.
    final offered = tagIdsAudibleOn([
      dep(id: 'live', tagId: 'tag-live', attached: lastMonth),
    ], today);
    expect(offered, {'tag-live'});
    expect(offered, isNot(contains('tag-boxed')));
  });

  test('a deployment with no attached date covers no day', () {
    // The same answer `tagIdsOnAnAnimalAt` and `DeploymentInterlock` give:
    // nobody said when the collar went on, so nothing can say it is on today.
    final offered = tagIdsAudibleOn([
      dep(id: 'undated', tagId: 'tag-undated', noAttachedDate: true),
    ], today);
    expect(offered, isEmpty);
  });

  test('a withdrawn deployment counts for nothing', () {
    final offered = tagIdsAudibleOn([
      dep(id: 'gone', tagId: 'tag-gone', attached: lastMonth, deleted: true),
    ], today);
    expect(offered, isEmpty,
        reason: 'a withdrawn link says the collar was never on this animal');
  });

  group('the removed-today boundary — a bare-day end covers its whole day', () {
    test('a collar removed TODAY is still offered today', () {
      final offered = tagIdsAudibleOn([
        dep(id: 'off-today', tagId: 'tag-off-today',
            attached: lastMonth, removed: DateTime(2026, 9, 14)),
      ], today);
      expect(offered, {'tag-off-today'},
          reason: 'the collar came off this morning and somebody recorded a '
              'bearing on it an hour earlier; that bearing is real and the '
              'wheel must still offer the collar for the rest of the day');
    });

    test('and is not offered tomorrow', () {
      final offered = tagIdsAudibleOn([
        dep(id: 'off-today', tagId: 'tag-off-today',
            attached: lastMonth, removed: DateTime(2026, 9, 14)),
      ], DateTime(2026, 9, 15, 6));
      expect(offered, isEmpty);
    });

    test('a collar removed yesterday is not offered today', () {
      final offered = tagIdsAudibleOn([
        dep(id: 'off-yesterday', tagId: 'tag-off-yesterday',
            attached: lastMonth, removed: yesterday),
      ], today);
      expect(offered, isEmpty);
    });

    test('a collar attached TODAY is offered today, and not yesterday', () {
      final deps = [
        dep(id: 'on-today', tagId: 'tag-on-today', attached: DateTime(2026, 9, 14)),
      ];
      expect(tagIdsAudibleOn(deps, today), {'tag-on-today'});
      expect(tagIdsAudibleOn(deps, yesterday), isEmpty);
    });

    test('a bare-day pair on one day — a row this app can no longer write '
        '(task 11.263) — still lists BOTH collars, without comment', () {
      // Two bare days on the 14th: what a build with the one-day allowance
      // wrote for a handover, and what the interlock refuses since design
      // §6a. The pair can still exist (an older build, another zone), and
      // the wheel reads it honestly: it is not claiming which collar the
      // animal is wearing, it is listing what can be heard, and for such a
      // pair that is two. Tasks 11.260 and 11.262 put a prompt above the
      // wheel for this state; 11.263 deleted it, and the wheel says nothing.
      final handover = [
        dep(id: 'old', tagId: 'tag-old', attached: lastMonth,
            removed: DateTime(2026, 9, 14)),
        dep(id: 'new', tagId: 'tag-new', attached: DateTime(2026, 9, 14)),
      ];
      expect(tagIdsAudibleOn(handover, today), {'tag-old', 'tag-new'});
      // And the day after, only the new one — the boundary from both sides.
      expect(tagIdsAudibleOn(handover, DateTime(2026, 9, 15)), {'tag-new'});
      // And the day before, only the old one.
      expect(tagIdsAudibleOn(handover, yesterday), {'tag-old'});
    });
  });

  test('the comparison is by local calendar day, not by instant', () {
    // A deployment date is a day (design §4). `today` here is 10:30 in the
    // morning; a deployment attached at that day's midnight is on today, and
    // one removed at that day's midnight is still on today — the time of day
    // the question is asked must not matter.
    final deps = [
      dep(id: 'a', tagId: 'tag-a', attached: DateTime(2026, 9, 14)),
      dep(id: 'b', tagId: 'tag-b', attached: lastMonth, removed: DateTime(2026, 9, 14)),
    ];
    expect(tagIdsAudibleOn(deps, DateTime(2026, 9, 14, 0, 0, 1)), {'tag-a', 'tag-b'});
    expect(tagIdsAudibleOn(deps, DateTime(2026, 9, 14, 23, 59, 59)), {'tag-a', 'tag-b'});
  });

  group('a TIMED removal — the boundary task 11.260 changed', () {
    test('the collar is offered right up to the instant it comes off, and '
        'not after — Michael, 2026-09-16: "wouldn\'t the old tag be with me '
        'not the animal?"', () {
      final offAtNoon = dep(id: 'y', tagId: 'tag-y', attached: lastMonth,
          removed: DateTime(2026, 9, 14, 12, 0));
      expect(tagIdsAudibleOn([offAtNoon], DateTime(2026, 9, 14, 11, 59)),
          {'tag-y'});
      expect(tagIdsAudibleOn([offAtNoon], DateTime(2026, 9, 14, 12, 0)),
          isEmpty,
          reason: 'coversMoment is half-open at a timed end');
      expect(tagIdsAudibleOn([offAtNoon], DateTime(2026, 9, 14, 15, 0)),
          isEmpty,
          reason: 'before task 11.260 this was still offered all day '
              '(Deployment.spansDay, since deleted) — exactly the case '
              'Michael found on his phone');
    });

    test('a timed handover shows only the new collar the instant it is '
        'confirmed, never both', () {
      final swapAt = DateTime(2026, 9, 14, 14, 32);
      final handover = [
        dep(id: 'old', tagId: 'tag-old', attached: lastMonth, removed: swapAt),
        dep(id: 'new', tagId: 'tag-new', attached: swapAt),
      ];
      expect(tagIdsAudibleOn(handover, DateTime(2026, 9, 14, 14, 31, 59)),
          {'tag-old'});
      expect(tagIdsAudibleOn(handover, swapAt), {'tag-new'});
      expect(tagIdsAudibleOn(handover, DateTime(2026, 9, 14, 20, 0)),
          {'tag-new'});
    });
  });

  group('tagIdsOnAnAnimalAt — the "Link a tag" picker asks the interlock\'s '
      'own arithmetic (task 11.251)', () {
    // The picker hides a collar only when linking it today would be refused.
    // Before this task it read the half-open `covers(today)`; when §4a
    // closed a date-only day at both ends, that reading would have hidden a
    // collar on the very day it came off — the day Michael moves it.
    test('a collar removed today as a BARE DAY is busy today (task 11.263): '
        'its removal covers the whole day, and a same-day handover needs a '
        'time', () {
      // Until 11.263 this was free — the one-day allowance let a bare-day
      // link today sit on a bare-day removal today. Now the two would
      // overlap and the write would refuse, so the picker withholds it. The
      // way to link it today is a time on the removal, on the animal's own
      // screen; `deployments_provider.dart` records this as the one case
      // where a collar that has been taken off is not offered.
      final deps = [
        dep(id: 'off-today', tagId: 'tag-off-today',
            attached: lastMonth, removed: DateTime(2026, 9, 14)),
      ];
      expect(tagIdsOnAnAnimalAt(deps, today), {'tag-off-today'});
      expect(
        DeploymentInterlock.conflictFor(
          DeploymentInterval(
            deploymentId: 'probe',
            tagId: 'tag-off-today',
            individualId: 'someone-else',
            attachedDate: DateTime(2026, 9, 14),
          ),
          deps.map((d) => d.interval),
        ),
        isNotNull,
        reason: 'and the write agrees',
      );
    });

    test('a collar removed yesterday is free today', () {
      final busy = tagIdsOnAnAnimalAt([
        dep(id: 'off-yesterday', tagId: 'tag-y',
            attached: lastMonth, removed: yesterday),
      ], today);
      expect(busy, isEmpty);
    });

    test('a collar removed at 09:15 today is free at 10:30 (the same-day '
        'move, with the time the swap will carry) — and busy at 09:00', () {
      // `today` is 10:30. The link would be a same-day swap stamped with
      // that instant (`LinkPlan.isSwap`), which starts after the 09:15
      // removal; a probe using the bare day would have found the morning
      // overlapping and hidden the one collar Michael is about to move.
      final deps = [
        dep(id: 'off-today', tagId: 'tag-off-today',
            attached: lastMonth, removed: DateTime(2026, 9, 14, 9, 15)),
      ];
      expect(tagIdsOnAnAnimalAt(deps, today), isEmpty);
      // Asked before the collar came off, it is still on — busy, and the
      // write would refuse the swap too.
      expect(
        tagIdsOnAnAnimalAt(deps, DateTime(2026, 9, 14, 9, 0)),
        {'tag-off-today'},
      );
    });

    test('a collar still on is busy; one with no attached date is not', () {
      final busy = tagIdsOnAnAnimalAt([
        dep(id: 'on', tagId: 'tag-on', attached: lastMonth),
        dep(id: 'undated', tagId: 'tag-undated', noAttachedDate: true),
        dep(id: 'gone', tagId: 'tag-gone', attached: lastMonth, deleted: true),
      ], today);
      expect(busy, {'tag-on'});
    });

    test('a collar coming off TOMORROW is busy today — the one-day allowance '
        'is withdrawn (task 11.263), and the picker agrees with the write', () {
      // A pre-check may be more permissive than the write it precedes; it
      // must never be less. Until 11.263 the interlock permitted this (a
      // one-day overlap, for the person recording a swap a day late) and the
      // picker offered it; now the write refuses it, so the picker withholds
      // it — asserted side by side so the two cannot drift.
      final deps = [
        dep(id: 'off-tomorrow', tagId: 'tag-t',
            attached: lastMonth, removed: DateTime(2026, 9, 15)),
      ];
      expect(tagIdsOnAnAnimalAt(deps, today), {'tag-t'});
      expect(
        DeploymentInterlock.conflictFor(
          DeploymentInterval(
            deploymentId: 'probe',
            tagId: 'tag-t',
            individualId: 'someone-else',
            attachedDate: DateTime(2026, 9, 14),
          ),
          deps.map((d) => d.interval),
        ),
        isNotNull,
        reason: 'and the write agrees',
      );
    });
  });
}

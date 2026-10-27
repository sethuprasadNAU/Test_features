import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/models/deployment.dart';
import 'package:tritrack/data/repositories/deployment_repository.dart';

import 'fixtures.dart';

/// **Task 11.251 — what a dated interval means when a bearing has a clock**
/// (`ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §4a), asserted on the model with no
/// repository, screen or fixture in between.
///
/// Every date here is a **local** `DateTime`, the way `deploymentDateFor`
/// writes one, because the rule is about local calendar days and a UTC
/// midnight is a bare day only in Greenwich.
///
/// The first group is the pair of defects Michael saw on his map on
/// 2026-09-15, each watched red against the half-open `covers()` this
/// replaced before the fix was written: a 2 p.m. bearing on the day a collar
/// came off was `false` for that deployment (the grey bearing) and `true`
/// for the one attached that same midnight with no end (the yellow one).
void main() {
  final removalDay = DateTime(2026, 9, 15);
  final twoPm = DateTime(2026, 9, 15, 14, 0);
  final lastMonth = DateTime(2026, 8, 1);

  group('rule 1 — a date-only deployment covers the whole of both its end days', () {
    test('THE GREY BEARING: a bearing on the day a collar comes off is inside '
        'the deployment it came off', () {
      final offToday = sampleDeployment(
        id: 'off-today',
        tagId: 'tag-1',
        individualId: 'a',
        attachedDate: lastMonth,
        removedDate: removalDay,
      );
      expect(
        offToday.coversMoment(twoPm),
        isTrue,
        reason: 'removed on the 15th means the 15th is the last day it was '
            'on, not the instant it stopped being on — before this task '
            'every bearing on a removal day went to nobody',
      );
      expect(offToday.coversMoment(DateTime(2026, 9, 15, 23, 59, 59)), isTrue);
      expect(
        offToday.coversMoment(DateTime(2026, 9, 16)),
        isFalse,
        reason: 'the day after is outside — the end is closed, not open',
      );
    });

    test('the attached day is whole as well, so the morning before the tap '
        'is inside', () {
      final onToday = sampleDeployment(
        id: 'on-today',
        tagId: 'tag-2',
        individualId: 'a',
        attachedDate: removalDay,
      );
      expect(onToday.coversMoment(DateTime(2026, 9, 15, 0, 0, 1)), isTrue);
      expect(onToday.coversMoment(twoPm), isTrue);
      expect(onToday.coversMoment(DateTime(2026, 9, 14, 23, 59)), isFalse);
    });

    test('THE YELLOW BEARING, half of it: on a date-only handover day the '
        'incoming deployment covers the moment too — which is why the '
        'derivation must report it as contested rather than pick', () {
      // The old half-open reading handed the whole day to the incoming
      // collar. Closing the day does not make the incoming collar *stop*
      // covering the afternoon — it cannot, without a time — so the model
      // says yes for both and `animalForObservationIn` refuses to choose.
      final outgoing = sampleDeployment(
        id: 'b',
        tagId: 'tag-2',
        individualId: 'b',
        attachedDate: lastMonth,
        removedDate: removalDay,
      );
      final incoming = sampleDeployment(
        id: 'a',
        tagId: 'tag-2',
        individualId: 'a',
        attachedDate: removalDay,
      );
      expect(outgoing.coversMoment(twoPm), isTrue);
      expect(incoming.coversMoment(twoPm), isTrue);
      final answer = DeploymentRepository.animalForObservationIn(
        [outgoing, incoming],
        tagId: 'tag-2',
        at: twoPm,
      );
      expect(answer.isContested, isTrue);
      expect(answer.sole, isNull, reason: 'no getter hands back one of two');
      expect(answer.candidates, ['b', 'a']);
      expect(answer.mayBe('a'), isTrue);
      expect(answer.mayBe('b'), isTrue);
      expect(answer.mayBe('c'), isFalse);
    });
  });

  group('rule 2 — a time beats a day', () {
    final swapAt = DateTime(2026, 9, 15, 14, 32);
    final outgoing = sampleDeployment(
      id: 'b',
      tagId: 'tag-2',
      individualId: 'b',
      attachedDate: lastMonth,
      removedDate: swapAt,
    );
    final incoming = sampleDeployment(
      id: 'a',
      tagId: 'tag-2',
      individualId: 'a',
      attachedDate: swapAt,
    );

    test('THE YELLOW BEARING, resolved: before the swap the collar is the old '
        "animal's, after it the new animal's, and nothing is contested", () {
      String? at(DateTime moment) => DeploymentRepository.animalForObservationIn(
        [outgoing, incoming],
        tagId: 'tag-2',
        at: moment,
      ).sole;
      expect(at(DateTime(2026, 9, 15, 10, 0)), 'b',
          reason: 'recorded hours before the collar went anywhere near A');
      expect(at(DateTime(2026, 9, 15, 14, 31, 59)), 'b');
      expect(at(swapAt), 'a', reason: 'the instant itself is half-open');
      expect(at(DateTime(2026, 9, 15, 16, 0)), 'a');
    });

    test('a timed end is an instant even when the other end is a day', () {
      // Michael's actual flow: the removal from B was picked with a time,
      // the link to A was confirmed with one — but a device that skipped
      // one of the two still gets an instant where it has one.
      final timedEndOnly = sampleDeployment(
        id: 'x',
        tagId: 'tag-x',
        individualId: 'b',
        attachedDate: lastMonth,
        removedDate: swapAt,
      );
      expect(timedEndOnly.coversMoment(DateTime(2026, 9, 15, 14, 0)), isTrue);
      expect(timedEndOnly.coversMoment(DateTime(2026, 9, 15, 15, 0)), isFalse,
          reason: 'the whole-day rule is for dates; this end has a time');
    });

    test('deploymentEndHasTime reads the value itself: midnight is a day, '
        'anything else is a moment', () {
      expect(deploymentEndHasTime(removalDay), isFalse);
      expect(deploymentEndHasTime(deploymentDateFor(DateTime.now())), isFalse);
      expect(deploymentEndHasTime(swapAt), isTrue);
      expect(deploymentEndHasTime(DateTime(2026, 9, 15, 0, 0, 1)), isTrue);
    });
  });

  group('coversMoment is answered for nothing without an attached date '
      '(design §4)', () {
    test('an undated deployment covers no moment', () {
      final undated = sampleDeployment(
        id: 'u',
        tagId: 'tag-u',
        individualId: 'a',
        noAttachedDate: true,
      );
      expect(undated.coversMoment(twoPm), isFalse);
    });
  });

  // **`spansDay` — the day-granular question task 11.249 wrote for the
  // Record wheel — is gone, deleted by task 11.260.** The wheel asks
  // `coversMoment` now, the same as every other reader; see
  // `deployments_provider.dart`'s `tagIdsAudibleOn` for why, and
  // `tag_ids_audible_on_test.dart` for the boundaries. A model method with
  // no caller left in `lib/` was the stale fact, not a feature to keep
  // beside it.

  group('AnimalAttribution', () {
    test('two deployments of one collar on the SAME animal are one answer, '
        'not a contest', () {
      // Two rows of one collar on one animal covering the same moment — a
      // pair a build with the one-day allowance could write (the interlock
      // refuses it since task 11.263) — name one animal twice, and a bird
      // named twice is not an ambiguous bird.
      final answer = AnimalAttribution.among(['a', 'a']);
      expect(answer.sole, 'a');
      expect(answer.isContested, isFalse);
    });

    test('nobody is nobody', () {
      expect(AnimalAttribution.among(const []).isNobody, isTrue);
      expect(AnimalAttribution.nobody.mayBe('a'), isFalse);
      expect(AnimalAttribution.nobody.sole, isNull);
    });
  });
}

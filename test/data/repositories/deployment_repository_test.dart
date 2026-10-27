import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/deployment.dart';
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.243: the dated link, and the two answers that look like bugs.**
///
/// `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §§2, 4, 6 and 7. The group
/// names below say *DELIBERATE* where the behaviour is counter-intuitive and
/// correct, so that a later reader meeting one of them finds a test arguing
/// for it rather than a comment.
void main() {
  late AppDatabase database;
  late DeploymentRepository deployments;
  late TagRepository tags;
  late IndividualRepository individuals;
  const projectId = 'project-1';
  final actor = MutationActor.user('user-1');

  // **Local** midnights, the way `deploymentDateFor` writes a deployment
  // date. A UTC midnight is a bare day only in Greenwich — anywhere else it
  // reads as a *time* under design §4a, and a test built on one would pass
  // in one zone and fail in another (task 11.251).
  DateTime d(int day) => DateTime(2026, 3, day);

  setUp(() async {
    database = await AppDatabase.openInMemory();
    deployments = DeploymentRepository(database.raw);
    tags = TagRepository(database.raw);
    individuals = IndividualRepository(database.raw);
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject(id: projectId));
    await individuals.insert(sampleIndividual(id: 'marie', name: 'Marie'));
    await individuals.insert(sampleIndividual(id: 'kea', name: 'Kea'));
    await tags.insert(sampleTag(id: 'collar-a', tagName: 'A'));
    await tags.insert(sampleTag(id: 'collar-b', tagName: 'B'));
    await tags.insert(sampleTag(id: 'collar-c', tagName: 'C'));
    await tags.insert(sampleTag(id: 'collar-d', tagName: 'D'));
  });

  tearDown(() => database.close());

  group("an observation's animal is derived by interval", () {
    test('a bearing inside the deployment belongs to that animal', () async {
      await deployments.link(
        sampleDeployment(
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(10),
        ),
      );
      expect(
        DeploymentRepository.animalForObservationIn(
          await deployments.findByProject(projectId),
          tagId: 'collar-a',
          at: d(5),
        ).sole,
        'marie',
      );
    });

    test('a collar moved between animals attributes each window correctly',
        () async {
      // The case the whole table exists for, and the one the old
      // `Tags.individual_id` could not express without a second inventory
      // row: one physical collar, refurbished, on a second animal.
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(10),
        ),
      );
      // The second half as two bare days on the 10th — **planted past the
      // interlock**, which refuses this pair since task 11.263 (design §6a).
      // The pair can still exist (an older build, another zone), and this
      // test is about how it is *read*; the write's refusal is asserted in
      // the interlock group below.
      await deployments.insertRow(
        sampleDeployment(
          id: 'd2',
          tagId: 'collar-a',
          individualId: 'kea',
          attachedDate: d(10),
        ).toColumns(),
      );
      Future<AnimalAttribution> at(DateTime moment) async =>
          DeploymentRepository.animalForObservationIn(
            await deployments.findByProject(projectId),
            tagId: 'collar-a',
            at: moment,
          );
      expect((await at(d(5))).sole, 'marie');
      expect((await at(d(20))).sole, 'kea');
      // **The handover day, with dates only, is contested** (design §4a,
      // task 11.251). It used to go to the incoming collar — the interval
      // was half-open so that one bearing could not be inside two
      // deployments — and that reading put every bearing on a removal day
      // in *no* deployment, which Michael saw as a grey bearing on his map.
      // A date cannot say which animal a 2 p.m. bearing was about; the
      // derivation says so instead of guessing, and a swap recorded with a
      // time (below) is what resolves it.
      final handoverDay = await at(DateTime(2026, 3, 10, 14, 0));
      expect(handoverDay.isContested, isTrue);
      expect(handoverDay.candidates, unorderedEquals(['marie', 'kea']));
      expect(handoverDay.sole, isNull);
    });

    test('DELIBERATE: a bearing with no covering deployment has no animal',
        () async {
      // **Design §2, the second of the three things this table buys.** A
      // collar that falls off keeps transmitting; bearings taken on it
      // afterwards belong to nobody, and saying so is the honest answer.
      //
      // *The natural implementation quietly attributes them to the most
      // recent animal instead* — which is exactly the lie the old column
      // told. This assertion is here so a later "fix" has to argue with a
      // test rather than with a comment.
      await deployments.link(
        sampleDeployment(
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(10),
        ),
      );
      expect(
        DeploymentRepository.animalForObservationIn(
          await deployments.findByProject(projectId),
          tagId: 'collar-a',
          at: d(20),
        ).isNobody,
        isTrue,
        reason: 'the collar came off on the 10th and kept transmitting',
      );
      expect(
        DeploymentRepository.animalForObservationIn(
          await deployments.findByProject(projectId),
          tagId: 'collar-a',
          at: DateTime.utc(2025, 12, 1),
        ).isNobody,
        isTrue,
        reason: 'and it was on nobody before it went on',
      );
    });

    test('DELIBERATE: a deployment with no attached date attributes nothing',
        () async {
      // **Design §4**, and Michael named it as the thing that will look like
      // a bug the first time he meets it. Nobody said when the collar went
      // on, so nothing can be said about which bearings it covers — including
      // bearings taken while it demonstrably was on.
      await deployments.link(
        sampleDeployment(
          tagId: 'collar-a',
          individualId: 'marie',
          noAttachedDate: true,
        ),
      );
      final stored = (await deployments.findByProject(projectId)).single;
      expect(stored.attachedDate, isNull, reason: 'the fixture did what it said');
      for (final day in [1, 5, 20]) {
        expect(
          DeploymentRepository.animalForObservationIn(
            await deployments.findByProject(projectId),
            tagId: 'collar-a',
            at: d(day),
          ).isNobody,
          isTrue,
        );
      }
    });

    test('a withdrawn link never happened', () async {
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      await deployments.unlink('d1', projectId: projectId, actor: actor);
      expect(
        DeploymentRepository.animalForObservationIn(
          await deployments.findByProject(projectId),
          tagId: 'collar-a',
          at: d(5),
        ).isNobody,
        isTrue,
      );
    });

    test('an open-ended deployment covers everything after it starts',
        () async {
      await deployments.link(
        sampleDeployment(
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      expect(
        DeploymentRepository.animalForObservationIn(
          await deployments.findByProject(projectId),
          tagId: 'collar-a',
          at: DateTime.utc(2030),
        ).sole,
        'marie',
      );
    });
  });

  group('design §4a — a day is a whole day, a time beats a day, and a moment '
      'two deployments cover is contested (task 11.251)', () {
    test('THE GREY BEARING, through the real write path: a bearing on the '
        'day a collar comes off is attributed to the animal it came off',
        () async {
      // §5a closes an animal's previous collar automatically whenever a new
      // one goes on, so "a removal day" is every ordinary recapture — this
      // was data loss on the common case, not a swap edge.
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      final stored = (await deployments.findByProject(projectId)).single;
      await deployments.update(
        stored.copyWith(removedDate: d(10)),
        actor: actor,
      );
      final answer = DeploymentRepository.animalForObservationIn(
        await deployments.findByProject(projectId),
        tagId: 'collar-a',
        at: DateTime(2026, 3, 10, 14, 0),
      );
      expect(answer.sole, 'marie',
          reason: 'removed on the 10th: the 10th was still hers');
      expect(
        DeploymentRepository.animalForObservationIn(
          await deployments.findByProject(projectId),
          tagId: 'collar-a',
          at: DateTime(2026, 3, 11, 9, 0),
        ).isNobody,
        isTrue,
        reason: 'and the 11th is not',
      );
    });

    test('THE YELLOW BEARING: a swap recorded with a time splits the day '
        'at that instant, and the interlock calls it no overlap at all',
        () async {
      final swapAt = DateTime(2026, 3, 10, 14, 32);
      await deployments.link(
        sampleDeployment(
          id: 'on-kea',
          tagId: 'collar-a',
          individualId: 'kea',
          attachedDate: d(1),
          removedDate: swapAt,
        ),
      );
      await deployments.link(
        sampleDeployment(
          id: 'on-marie',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: swapAt,
        ),
      );
      final rows = await deployments.findByProject(projectId);
      expect(rows, hasLength(2), reason: 'the interlock let the swap through');
      expect(
        DeploymentInterlock.overlaps(rows[0].interval, rows[1].interval),
        isFalse,
        reason: 'same instant at both ends: touching, not overlapping',
      );
      AnimalAttribution at(DateTime moment) =>
          DeploymentRepository.animalForObservationIn(
            rows,
            tagId: 'collar-a',
            at: moment,
          );
      expect(at(DateTime(2026, 3, 10, 10, 0)).sole, 'kea',
          reason: 'recorded hours before the collar went near Marie');
      expect(at(DateTime(2026, 3, 10, 16, 0)).sole, 'marie');
      expect(at(DateTime(2026, 3, 10, 10, 0)).isContested, isFalse);
      // The round trip through SQLite kept the time — a value written as
      // 14:32 must not come back as a day.
      expect(deploymentEndHasTime(rows[0].removedDate!), isTrue);
      expect(rows[0].removedDate!.toLocal(), swapAt);
    });

    test('THE CONTESTED PATH STAYS REACHABLE for a pair that already exists: '
        'two bare days both covering the 9th and 10th, planted past the '
        'interlock, are still read as contested — and the same pair can no '
        'longer be written (task 11.263)', () async {
      // Until task 11.263 the interlock permitted a one-day overlap of whole
      // days, so this pair went in through `link`. It is refused now (design
      // §6a) — asserted below — but a pair like it can already exist: written
      // by a build with the allowance, or in another zone (§4). The
      // interlock governs writes, not reads, so the attribution's honest
      // answer for it must survive: the 9th and the 10th are inside both
      // deployments and neither animal is picked.
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(10),
        ),
      );
      final legacy = sampleDeployment(
        id: 'd2',
        tagId: 'collar-a',
        individualId: 'kea',
        attachedDate: d(9),
      );
      await expectLater(
        deployments.link(legacy),
        throwsA(isA<OverlappingDeployment>()),
        reason: 'the 9th and the 10th would be inside both — refused since '
            'task 11.263, permitted as "one day" before it',
      );
      // Planted the way an older build left it: straight into the table,
      // past the rule.
      await deployments.insertRow(legacy.toColumns());
      final rows = await deployments.findByProject(projectId);
      expect(rows, hasLength(2), reason: 'the pair is there to read');
      expect(
        DeploymentInterlock.overlaps(rows[0].interval, rows[1].interval),
        isTrue,
      );
      // Both the 9th and the 10th are contested — two whole days inside two
      // deployments, which is what a day-late swap honestly is.
      for (final moment in [DateTime(2026, 3, 9, 12), DateTime(2026, 3, 10, 12)]) {
        expect(
          DeploymentRepository.animalForObservationIn(
            rows,
            tagId: 'collar-a',
            at: moment,
          ).isContested,
          isTrue,
        );
      }
      // Either side of the pair the answer is still one animal.
      expect(
        DeploymentRepository.animalForObservationIn(
          rows,
          tagId: 'collar-a',
          at: DateTime(2026, 3, 8, 12),
        ).sole,
        'marie',
      );
      expect(
        DeploymentRepository.animalForObservationIn(
          rows,
          tagId: 'collar-a',
          at: DateTime(2026, 3, 11, 12),
        ).sole,
        'kea',
      );
    });
  });

  group('the interlock, enforced at the write (design §6)', () {
    test('one animal cannot wear two collars at once', () async {
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      await expectLater(
        deployments.link(
          sampleDeployment(
            id: 'd2',
            tagId: 'collar-b',
            individualId: 'marie',
            attachedDate: d(1),
          ),
        ),
        throwsA(
          isA<OverlappingDeployment>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('two tags at once'),
              contains('attached and removed dates'),
            ),
          ),
        ),
      );
      expect(
        await deployments.findByProject(projectId),
        hasLength(1),
        reason: 'refused, never silently adjusted',
      );
    });

    test('one collar cannot be on two animals at once', () async {
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      await expectLater(
        deployments.link(
          sampleDeployment(
            id: 'd2',
            tagId: 'collar-a',
            individualId: 'kea',
            attachedDate: d(1),
          ),
        ),
        throwsA(
          isA<OverlappingDeployment>().having(
            (e) => e.message,
            'message',
            contains('two animals at once'),
          ),
        ),
      );
    });

    test('the same-day handover is permitted when it carries a time, which '
        'is what the app writes — and refused as two bare days (task 11.263)',
        () async {
      // §5a: the app writes the same *instant* to one deployment's end and
      // the next one's start. Two intervals that meet at a point overlap by
      // nothing, so **the interlock never fires on the ordinary case** —
      // which is what makes it a guard rather than an obstacle.
      final swapAt = DateTime(2026, 3, 10, 14, 32);
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: swapAt,
        ),
      );
      await deployments.link(
        sampleDeployment(
          id: 'd2',
          tagId: 'collar-b',
          individualId: 'marie',
          attachedDate: swapAt,
        ),
      );
      expect(await deployments.findByProject(projectId), hasLength(2));

      // The same handover as two bare days both cover the whole of the
      // 10th. Permitted until task 11.263 under the one-day allowance;
      // refused since, because a bearing that afternoon would be inside
      // both with nothing to say which animal it was about.
      await deployments.link(
        sampleDeployment(
          id: 'd3',
          tagId: 'collar-c',
          individualId: 'kea',
          attachedDate: d(1),
          removedDate: d(10),
        ),
      );
      await expectLater(
        deployments.link(
          sampleDeployment(
            id: 'd4',
            tagId: 'collar-d',
            individualId: 'kea',
            attachedDate: d(10),
          ),
        ),
        throwsA(
          isA<OverlappingDeployment>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('two tags at once'),
              contains('do not overlap'),
              isNot(contains('more than a day')),
            ),
          ),
        ),
      );
    });

    test('an overlap of one bare day is refused, the same as one of two',
        () async {
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(10),
        ),
      );
      await expectLater(
        deployments.link(
          sampleDeployment(
            id: 'd2',
            tagId: 'collar-b',
            individualId: 'marie',
            attachedDate: d(10),
            removedDate: d(20),
          ),
        ),
        throwsA(isA<OverlappingDeployment>()),
        reason: 'the 10th is inside both',
      );
      await expectLater(
        deployments.link(
          sampleDeployment(
            id: 'd3',
            tagId: 'collar-b',
            individualId: 'marie',
            attachedDate: d(9),
            removedDate: d(20),
          ),
        ),
        throwsA(isA<OverlappingDeployment>()),
      );
      // The day after is free.
      await deployments.link(
        sampleDeployment(
          id: 'd4',
          tagId: 'collar-b',
          individualId: 'marie',
          attachedDate: d(11),
          removedDate: d(20),
        ),
      );
      expect(await deployments.findByProject(projectId), hasLength(2));
    });

    test('editing a deployment is checked too, against everything but itself',
        () async {
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(10),
        ),
      );
      await deployments.link(
        sampleDeployment(
          id: 'd2',
          tagId: 'collar-b',
          individualId: 'marie',
          attachedDate: d(11),
        ),
      );
      final first = (await deployments.findById('d1', projectId: projectId))!;
      // Correcting its own notes must not find it conflicting with its
      // former self.
      await deployments.update(
        first.copyWith(notes: 'fitted at the nest'),
        actor: actor,
      );
      expect(
        (await deployments.findById('d1', projectId: projectId))!.notes,
        'fitted at the nest',
      );
      // Moving its end onto the second one's start day is refused: the 11th
      // would be inside both.
      await expectLater(
        deployments.update(
          first.copyWith(removedDate: d(11)),
          actor: actor,
        ),
        throwsA(isA<OverlappingDeployment>()),
      );
    });

    test('DELIBERATE: a deployment with no attached date conflicts with '
        'nothing', () async {
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      await deployments.link(
        sampleDeployment(
          id: 'd2',
          tagId: 'collar-b',
          individualId: 'marie',
          noAttachedDate: true,
        ),
      );
      expect(await deployments.findByProject(projectId), hasLength(2));
    });
  });

  group('the lists a screen reads', () {
    test("Marie's collars are every collar she has worn, in order", () async {
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(10),
        ),
      );
      await deployments.link(
        sampleDeployment(
          id: 'd2',
          tagId: 'collar-b',
          individualId: 'marie',
          attachedDate: d(11),
        ),
      );
      expect(
        (await deployments.findByIndividual('marie', projectId: projectId))
            .map((x) => x.tagId),
        ['collar-a', 'collar-b'],
      );
      expect(
        (await tags.findByIndividual('marie', projectId: projectId))
            .map((t) => t.tagId)
            .toSet(),
        {'collar-a', 'collar-b'},
      );
    });

    test('"whose collar is this" is the latest deployment, and it is NOT the '
        'interval answer', () async {
      // **The distinction the whole screen layer depends on.** A collar that
      // came off Marie in June is still *listed under Marie* — she is whose
      // collar it is — while every bearing taken on it since June is
      // attributed to **nobody**. Both are right and they are asked by
      // different callers; asserting them side by side is the only way the
      // difference stays deliberate.
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(10),
        ),
      );
      expect(
        await deployments.latestAnimalForTag('collar-a', projectId: projectId),
        'marie',
        reason: 'it is still her collar',
      );
      expect(
        DeploymentRepository.animalForObservationIn(
          await deployments.findByProject(projectId),
          tagId: 'collar-a',
          at: d(20),
        ).isNobody,
        isTrue,
        reason: 'and a bearing taken after it came off is about nobody',
      );

      await deployments.link(
        sampleDeployment(
          id: 'd2',
          tagId: 'collar-a',
          individualId: 'kea',
          attachedDate: d(11),
        ),
      );
      expect(
        await deployments.latestAnimalForTag('collar-a', projectId: projectId),
        'kea',
      );
    });
  });

  group('a deployment whose animal is a tombstone — task 11.258', () {
    // The app's own two writers never leave one of these (`IndividualMerge`
    // re-points, `DeploymentLinking.deleteAnimal` withdraws), so this
    // reaches in past `IndividualRepository.remove` directly — the shape a
    // sync from a device that raced the two would deliver.
    test('"whose collar is this" skips it and falls to the next live '
        'deployment, or to none', () async {
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(5),
        ),
      );
      await individuals.remove(
        'marie',
        projectId: projectId,
        actor: actor,
      );
      expect(
        await deployments.latestAnimalForTag('collar-a', projectId: projectId),
        null,
        reason: 'the only deployment on the collar names a tombstoned animal',
      );
      expect(
        (await tags.findById('collar-a', projectId: projectId))!.individualName,
        null,
        reason: 'the read join must not carry the dead row\'s name forward',
      );

      // A second, live animal's deployment on the same collar, opened after
      // the first came off, is still found — the tombstoned row is skipped,
      // not the whole collar.
      await deployments.link(
        sampleDeployment(
          id: 'd2',
          tagId: 'collar-a',
          individualId: 'kea',
          attachedDate: d(11),
        ),
      );
      expect(
        await deployments.latestAnimalForTag('collar-a', projectId: projectId),
        'kea',
      );
      expect(
        (await tags.findById('collar-a', projectId: projectId))!.individualName,
        'Kea',
      );
    });

    test('DELIBERATE: a bearing keeps resolving to the animal that wore the '
        'collar at the time, tombstoned or not — the history question is '
        'not the grouping question', () async {
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(10),
        ),
      );
      await individuals.remove(
        'marie',
        projectId: projectId,
        actor: actor,
      );
      expect(
        DeploymentRepository.animalForObservationIn(
          await deployments.findByProject(projectId),
          tagId: 'collar-a',
          at: d(5),
        ).sole,
        'marie',
        reason:
            'the bearing was taken while marie wore the collar; deleting '
            'her afterwards does not rewrite what it was about',
      );
    });
  });

  group('the row the validator refuses', () {
    test('a collar cannot come off before it went on', () {
      final issues = RowValidator.validate(Tables.deployments, {
        'deployment_id': 'd1',
        'project_id': projectId,
        'tag_id': 'collar-a',
        'individual_id': 'marie',
        'attached_date': DbCodec.encodeUtc(d(10)),
        'removed_date': DbCodec.encodeUtc(d(1)),
        'created_at': DbCodec.encodeUtc(d(1)),
        'updated_at': DbCodec.encodeUtc(d(1)),
        'revision': 0,
      });
      expect(issues.map((i) => i.field), contains('removed_date'));
    });

    test('and accepts the ordinary one', () {
      final issues = RowValidator.validate(Tables.deployments, {
        'deployment_id': 'd1',
        'project_id': projectId,
        'tag_id': 'collar-a',
        'individual_id': 'marie',
        'attached_date': DbCodec.encodeUtc(d(1)),
        'removed_date': null,
        'notes': null,
        'created_at': DbCodec.encodeUtc(d(1)),
        'updated_at': DbCodec.encodeUtc(d(1)),
        'revision': 0,
      });
      expect(issues, isEmpty, reason: issues.map((i) => i.message).join('; '));
    });
  });
}

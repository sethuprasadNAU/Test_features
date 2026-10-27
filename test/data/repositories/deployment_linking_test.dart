import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/deployment_linking.dart';
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.244 — §5a: the dates fill themselves in, and the app says so.**
///
/// The two things this file exists to hold, and they pull in opposite
/// directions:
///
/// 1. **The recapture passes.** §5a's flow writes the same *instant* to one
///    deployment's end and the next one's start — an overlap of nothing —
///    so the interlock must *not* fire on it. **A guard that blocks the
///    ordinary case is worse than no guard.**
/// 2. **A real conflict is refused**, and the refusal was watched red rather
///    than assumed: the group below removes the closing step and asserts the
///    same link is then turned away.
///
/// **Every bare day here is a local `DateTime`** (task 11.263). This file
/// used `DateTime.utc`, which on the Arizona machine it mostly runs on is
/// 17:00 the evening before — a *timed* value to `deploymentEndHasTime` —
/// and a bare day only on a UTC runner. With the one-day allowance gone the
/// two readings give different interlock answers, so the fixtures now say
/// which they mean.
void main() {
  late AppDatabase database;
  late DeploymentLinking linking;
  late DeploymentRepository deployments;
  late IndividualRepository individuals;
  const projectId = 'project-1';
  final actor = MutationActor.user('user-1');

  /// A bare day, as the app writes one: local midnight.
  DateTime d(int day) => DateTime(2026, 3, day);

  /// The instant the confirmation stamps on a swap confirmed at 14:32.
  final swapAt = DateTime(2026, 3, 10, 14, 32, 50);

  setUp(() async {
    database = await AppDatabase.openInMemory();
    linking = DeploymentLinking(database.raw);
    deployments = DeploymentRepository(database.raw);
    individuals = IndividualRepository(database.raw);
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject(id: projectId));
    await individuals.insert(sampleIndividual(id: 'marie', name: 'Marie'));
    await individuals.insert(sampleIndividual(id: 'kea', name: 'Kea'));
    final tags = TagRepository(database.raw);
    await tags.insert(sampleTag(id: 'collar-a', tagName: '150.321'));
    await tags.insert(sampleTag(id: 'collar-b', tagName: '150.523'));
    await tags.insert(sampleTag(id: 'collar-c', tagName: '150.700'));
  });

  tearDown(() => database.close());

  group('the plan says what will happen before anything is written', () {
    test('an animal wearing nothing: one row, and nothing else is touched',
        () async {
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'collar-a',
        individualId: 'marie',
        attachedDate: d(10),
      );
      expect(plan.closing, isNull);
      expect(
        plan.amendsAnotherRow,
        isFalse,
        reason: 'nothing unexpected to warn about, so the sentence is one line',
      );
      expect(await deployments.findByProject(projectId), isEmpty,
          reason: 'plan() reads; it writes nothing');
    });

    test('an animal already wearing one: the plan names the row it displaces',
        () async {
      await deployments.link(
        sampleDeployment(
          id: 'old',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'collar-b',
        individualId: 'marie',
        attachedDate: d(10),
      );
      expect(plan.closing!.deploymentId, 'old');
      expect(plan.closingDate, d(10), reason: 'the same day the new one goes on');
      expect(plan.amendsAnotherRow, isTrue);
    });

    test('DELIBERATE: a deployment that already has a removed date is left '
        'alone', () async {
      // §5a leaves this edge to the task. Somebody has already said when that
      // collar came off; overwriting it with today would be the app
      // correcting a field note nobody said was wrong.
      await deployments.link(
        sampleDeployment(
          id: 'closed',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(5),
        ),
      );
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'collar-b',
        individualId: 'marie',
        attachedDate: d(10),
      );
      expect(plan.closing, isNull);
    });

    test('DELIBERATE: a deployment with no attached date is not closed either',
        () async {
      // It covers no interval, so it conflicts with nothing and displaces
      // nothing. Closing it would invent the fact that it ended, on top of
      // the fact nobody recorded that it began.
      await deployments.link(
        sampleDeployment(
          id: 'undated',
          tagId: 'collar-a',
          individualId: 'marie',
          noAttachedDate: true,
        ),
      );
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'collar-b',
        individualId: 'marie',
        attachedDate: d(10),
      );
      expect(plan.closing, isNull);

      await linking.apply(plan, actor: actor);
      final stored = (await deployments.findById(
        'undated',
        projectId: projectId,
      ))!;
      expect(stored.attachedDate, isNull, reason: 'not silently given one');
      expect(stored.removedDate, isNull, reason: 'and not silently closed');
    });

    test('an animal that is not there is a screen mistake, not a state',
        () async {
      await expectLater(
        linking.plan(
          projectId: projectId,
          tagId: 'collar-a',
          individualId: 'nobody',
          attachedDate: d(10),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('applying the plan', () {
    test('THE ORDINARY CASE: the recapture passes the interlock', () async {
      // **The assertion this whole file is for.** §5a's flow, stamped with
      // the swap time the confirmation gives it (`LinkPlan.at`), produces
      // two intervals meeting at one instant — an overlap of nothing — so
      // the guard must not fire. The two tests below remove the closing
      // step, and then the time, and watch the same link refused, which is
      // what makes this green mean something.
      await deployments.link(
        sampleDeployment(
          id: 'old',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'collar-b',
        individualId: 'marie',
        attachedDate: d(10),
      );
      expect(plan.isSwap, isTrue, reason: 'she wears a collar that comes off');
      final created = await linking.apply(plan.at(swapAt), actor: actor);

      final hers = await deployments.findByIndividual(
        'marie',
        projectId: projectId,
      );
      expect(hers, hasLength(2));
      final old = hers.firstWhere((x) => x.deploymentId == 'old');
      expect(old.removedDate!.toLocal(), swapAt, reason: 'closed at the swap');
      expect(old.attachedDate!.toLocal(), d(1),
          reason: 'and nothing else about it moved');
      final now = hers.firstWhere((x) => x.deploymentId == created.deploymentId);
      expect(now.attachedDate!.toLocal(), swapAt);
      expect(now.removedDate, isNull, reason: 'the new collar is on');
      expect(
        DeploymentInterlock.overlaps(hers[0].interval, hers[1].interval),
        isFalse,
        reason: 'the same instant at both ends: touching, not overlapping',
      );
    });

    test('WATCHED RED (task 11.263): the same plan applied as a bare day — '
        'the swap time skipped — is refused, and writes nothing', () async {
      // Until task 11.263 this passed: two bare days on the 10th were a
      // "zero-day" overlap inside the one-day allowance. Now both rows
      // cover the whole of the 10th and the interlock refuses the pair —
      // and the transaction rolls the closing back with the link.
      await deployments.link(
        sampleDeployment(
          id: 'old',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'collar-b',
        individualId: 'marie',
        attachedDate: d(10),
      );
      await expectLater(
        linking.apply(plan, actor: actor),
        throwsA(
          isA<OverlappingDeployment>().having(
            (e) => e.message,
            'message',
            contains('two tags at once'),
          ),
        ),
      );
      final old = (await deployments.findById('old', projectId: projectId))!;
      expect(old.removedDate, isNull, reason: 'the closing rolled back too');
      expect(await deployments.findByProject(projectId), hasLength(1));
    });

    test("her previous collar came off earlier today, on her own screen: the "
        'plan is a swap so the link gets a time, and with it the link passes '
        '(task 11.263)', () async {
      // Tag 1 off Kea at 09:00 through her editor; tag 2 onto Kea this
      // afternoon through this link. Nothing is open to close, and tag 2
      // has no history — so before 11.263 this was not a swap and stayed a
      // bare day, which the one-day allowance let through. Now a bare day
      // from midnight would overlap the morning's deployment and be
      // refused; the plan says it is a swap, the confirmation stamps a
      // time, and the afternoon's link meets the morning's removal cleanly.
      await deployments.link(
        sampleDeployment(
          id: 'kea-morning',
          tagId: 'collar-a',
          individualId: 'kea',
          attachedDate: d(1),
          removedDate: DateTime(2026, 3, 10, 9, 0),
        ),
      );
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'collar-b',
        individualId: 'kea',
        attachedDate: d(10),
      );
      expect(plan.closing, isNull, reason: 'nothing is open');
      expect(plan.cameOffToday, isNull, reason: 'tag 2 has no history');
      expect(plan.herLastCameOffToday!.deploymentId, 'kea-morning');
      expect(plan.isSwap, isTrue);
      await expectLater(
        linking.apply(plan, actor: actor),
        throwsA(isA<OverlappingDeployment>()),
        reason: 'as a bare day it would cover the morning too',
      );
      await linking.apply(plan.at(swapAt), actor: actor);
      expect(await deployments.findByProject(projectId), hasLength(2));
    });

    test('a collar from the shelf onto a bare animal is not a swap, and the '
        'bare day passes', () async {
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'collar-b',
        individualId: 'kea',
        attachedDate: d(10),
      );
      expect(plan.isSwap, isFalse);
      await linking.apply(plan, actor: actor);
      final stored = (await deployments.findByProject(projectId)).single;
      expect(deploymentEndHasTime(stored.attachedDate!), isFalse,
          reason: "a time here could only lose the morning's bearings");
    });

    test('WATCHED RED: without the closing step the same link is refused',
        () async {
      // **The negative control.** This is §5a's flow with rule 2 removed —
      // exactly the state task 11.243 shipped, where putting a second collar
      // on an animal was turned away. If this ever stops throwing, the test
      // above is passing for the wrong reason.
      await deployments.link(
        sampleDeployment(
          id: 'old',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      await expectLater(
        deployments.link(
          sampleDeployment(
            id: 'new',
            tagId: 'collar-b',
            individualId: 'marie',
            attachedDate: d(10),
          ),
        ),
        throwsA(
          isA<OverlappingDeployment>().having(
            (e) => e.message,
            'message',
            contains('two tags at once'),
          ),
        ),
      );
    });

    test('a genuine conflict still refuses, and writes nothing at all',
        () async {
      // The collar being linked is already on a *different* animal, open
      // ended. Closing Marie's old collar cannot help that, so the interlock
      // fires — and the transaction must roll the closing back with it.
      await deployments.link(
        sampleDeployment(
          id: 'marie-old',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      await deployments.link(
        sampleDeployment(
          id: 'kea-current',
          tagId: 'collar-b',
          individualId: 'kea',
          attachedDate: d(1),
        ),
      );
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'collar-b',
        individualId: 'marie',
        attachedDate: d(10),
      );
      await expectLater(
        linking.apply(plan, actor: actor),
        throwsA(
          isA<OverlappingDeployment>().having(
            (e) => e.message,
            'message',
            contains('two animals at once'),
          ),
        ),
      );
      expect(
        (await deployments.findById('marie-old', projectId: projectId))!
            .removedDate,
        isNull,
        reason:
            'the closing rolled back with the link — half of this is worse '
            'than none, because it leaves the animal wearing nothing on a day '
            'she is wearing something',
      );
      expect(await deployments.findByProject(projectId), hasLength(2));
    });

    test('a viewer is refused and nothing is written', () async {
      await UserRepository(
        database.raw,
      ).insert(sampleUser(id: 'user-2', email: 'v@x.com'));
      await database.raw.insert(
        Tables.projectMemberships,
        sampleMembership(
          id: 'm-2',
          userId: 'user-2',
          role: ProjectRole.viewer,
        ).toColumns(),
      );
      await deployments.link(
        sampleDeployment(
          id: 'old',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
        ),
      );
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'collar-b',
        individualId: 'marie',
        attachedDate: d(10),
      );
      await expectLater(
        linking.apply(plan, actor: MutationActor.user('user-2')),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(
        (await deployments.findById('old', projectId: projectId))!.removedDate,
        isNull,
      );
      expect(await deployments.findByProject(projectId), hasLength(1));
    });
  });

  group('a tag that is not on the project yet goes on in the same write '
      '(task 11.321)', () {
    // Michael, 2026-09-30: linking a tag took three places — the Tag Library,
    // the project, then the animal. Now a library tag is copied in and
    // linked in one action, and a brand-new tag is created and linked in one.
    // **One action means one write**: a copy that landed without its link
    // would be a tag the person never asked for sitting on the project.

    test('a Tag Library tag is copied in and linked together', () async {
      final entry = sampleTagLibraryEntry(
        id: 'lib-rex',
        lineageId: 'l-rex',
        tagName: 'Rex',
        frequencyMhz: 150.900,
      );
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'rex-copy',
        individualId: 'marie',
        attachedDate: d(10),
      );
      await linking.apply(
        plan,
        actor: actor,
        adding: LibraryTagToAdd(entry),
      );
      final tag = await TagRepository(database.raw)
          .findById('rex-copy', projectId: projectId);
      expect(tag, isNotNull);
      expect(tag!.lineageId, 'l-rex',
          reason: 'a copy keeps the library entry\'s lineage, as More → Tags\'s '
              'own copy does');
      expect(tag.copiedAt, isNotNull);
      final hers = await deployments.findByIndividual('marie', projectId: projectId);
      expect(hers.single.tagId, 'rex-copy');
    });

    test('a new tag is created on the project and linked together', () async {
      final tag = sampleTag(id: 'new-tag', tagName: 'Zed', frequencyMhz: 151.0);
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'new-tag',
        individualId: 'marie',
        attachedDate: d(10),
      );
      await linking.apply(plan, actor: actor, adding: NewTagToAdd(tag));
      expect(
        await TagRepository(database.raw)
            .findById('new-tag', projectId: projectId),
        isNotNull,
      );
      final hers = await deployments.findByIndividual('marie', projectId: projectId);
      expect(hers.single.tagId, 'new-tag');
    });

    test('WATCHED RED: a link the deployment rules refuse leaves no copy '
        'behind', () async {
      // Marie already has a collar recorded on until the 20th. A new collar
      // from the 10th would put her in two at once, so the link is refused —
      // and the copy written a moment before it in the same action must go
      // with it.
      await deployments.link(
        sampleDeployment(
          id: 'marie-until-20',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(20),
        ),
      );
      final entry = sampleTagLibraryEntry(id: 'lib-rex', lineageId: 'l-rex');
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'rex-copy',
        individualId: 'marie',
        attachedDate: d(10),
      );
      await expectLater(
        linking.apply(plan, actor: actor, adding: LibraryTagToAdd(entry)),
        throwsA(isA<OverlappingDeployment>()),
      );
      expect(
        await TagRepository(database.raw)
            .findById('rex-copy', projectId: projectId, includeDeleted: true),
        isNull,
        reason: 'the copy rolled back with the refused link',
      );
    });

    test('a viewer is refused, and neither the tag nor the link is written',
        () async {
      await UserRepository(
        database.raw,
      ).insert(sampleUser(id: 'user-2', email: 'v@x.com'));
      await database.raw.insert(
        Tables.projectMemberships,
        sampleMembership(
          id: 'm-2',
          userId: 'user-2',
          role: ProjectRole.viewer,
        ).toColumns(),
      );
      final entry = sampleTagLibraryEntry(id: 'lib-rex', lineageId: 'l-rex');
      final plan = await linking.plan(
        projectId: projectId,
        tagId: 'rex-copy',
        individualId: 'marie',
        attachedDate: d(10),
      );
      await expectLater(
        linking.apply(
          plan,
          actor: MutationActor.user('user-2'),
          adding: LibraryTagToAdd(entry),
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(
        await TagRepository(database.raw)
            .findById('rex-copy', projectId: projectId, includeDeleted: true),
        isNull,
      );
      expect(await deployments.findByProject(projectId), isEmpty);
    });
  });

  group('the confirmation names both changes', () {
    test('the recapture sentence names both collars and both dates', () {
      // **Local dates, because that is what the app produces.** A deployment
      // date is the local calendar day at its own midnight — see
      // `deploymentDateFor` for why local rather than UTC — so a test that
      // built a UTC midnight here would assert the neighbouring date in
      // every zone west of Greenwich, which is where this was first run.
      final text = linkConfirmationText(
        tagName: '150.523',
        animalName: 'Marie',
        attachedDate: DateTime(2026, 3, 10),
        closingTagName: '150.321',
        closingDate: DateTime(2026, 3, 10),
      );
      // §5a's own example, in its own words.
      expect(text, contains('Link 150.523 to Marie, attached 2026-03-10.'));
      expect(
        text,
        contains("Marie's 150.321 will be recorded as removed 2026-03-10."),
      );
      expect(
        text,
        contains('a record you did not open'),
        reason:
            'the confirmation is not politeness — it exists because this '
            'writes to a row the person did not touch',
      );
    });

    test('a date picked today reads back as today, in this device\'s zone',
        () {
      // The round trip the person actually sees: `deploymentDateFor` takes
      // the local day, the column stores an instant, and the sentence reads
      // the same day back. **This is the assertion the timezone decision
      // rests on** — it was written after the first run of this file
      // produced 2026-03-09 for a date built as UTC midnight.
      final now = DateTime.now();
      final picked = deploymentDateFor(now);
      expect(formatLinkDate(picked), formatLinkDate(now));
      expect(picked.hour, 0);
      expect(picked.minute, 0);
    });

    test('with nothing to displace it is one line and warns about nothing',
        () {
      final text = linkConfirmationText(
        tagName: '150.523',
        animalName: 'Marie',
        attachedDate: DateTime(2026, 3, 10),
      );
      expect(text, 'Link 150.523 to Marie, attached 2026-03-10.');
      expect(text, isNot(contains('removed')));
    });
  });

  group('deleting an animal', () {
    test('withdraws every link and tombstones the animal, moving no bearing',
        () async {
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: d(1),
          removedDate: d(5),
        ),
      );
      await deployments.link(
        sampleDeployment(
          id: 'd2',
          tagId: 'collar-b',
          individualId: 'marie',
          attachedDate: d(6),
        ),
      );

      final withdrawn = await linking.deleteAnimal(
        projectId: projectId,
        individualId: 'marie',
        actor: actor,
      );

      expect(withdrawn, 2);
      expect(
        await deployments.findByIndividual('marie', projectId: projectId),
        isEmpty,
      );
      expect(await individuals.findById('marie', projectId: projectId), isNull);
      expect(
        await individuals.findById(
          'marie',
          projectId: projectId,
          includeDeleted: true,
        ),
        isNotNull,
        reason: 'a tombstone, never a hard delete',
      );
      // The collars are untouched and both are back on the shelf.
      final tags = TagRepository(database.raw);
      expect(await tags.findByProject(projectId), hasLength(3));
      for (final id in ['collar-a', 'collar-b']) {
        expect(
          await deployments.latestAnimalForTag(id, projectId: projectId),
          isNull,
          reason: '$id is on nobody now, which is an ordinary state for a '
              'transmitter (design §1)',
        );
      }
    });

    test('an animal with no collars deletes cleanly', () async {
      expect(
        await linking.deleteAnimal(
          projectId: projectId,
          individualId: 'kea',
          actor: actor,
        ),
        0,
      );
      expect(await individuals.findById('kea', projectId: projectId), isNull);
    });
  });
}

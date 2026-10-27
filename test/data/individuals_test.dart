import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/individual.dart';
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'fixtures.dart';

/// Task 11.240: the animal is a row of its own, and what that must and must
/// not change. **Rewritten by task 11.243**, which moved the link off the tag
/// and onto a dated `Deployments` row — so every question below that used to
/// be asked of `Tags.individual_id` is asked of a deployment instead.
void main() {
  late AppDatabase database;
  late TagRepository tags;
  late IndividualRepository individuals;
  late DeploymentRepository deployments;
  const projectId = 'project-1';
  final actor = MutationActor.user('user-1');

  setUp(() async {
    database = await AppDatabase.openInMemory();
    tags = TagRepository(database.raw);
    individuals = IndividualRepository(database.raw);
    deployments = DeploymentRepository(database.raw);
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject(id: projectId));
  });

  tearDown(() => database.close());

  group('an individual with no tag, and a tag with no individual', () {
    test('a chick identified but not yet collared is a row on its own',
        () async {
      await individuals.insert(sampleIndividual(id: 'chick', name: 'Chick'));
      final stored = await individuals.findById('chick', projectId: projectId);
      expect(stored, isNotNull);
      expect(await individuals.findByProject(projectId), hasLength(1));
      expect(await tags.findByProject(projectId), isEmpty);
    });

    test('creating a collar creates no animal at all, and that is the change',
        () async {
      // **Task 11.243.** Task 11.240's `insert` created one animal per tag,
      // named after the tag, because a `Tags` row was a deployment with a NOT
      // NULL date — so there was by construction an animal. Design §1: a tag
      // is equipment, entered before any animal exists, and **a collar with
      // no animal is the normal starting state rather than an exception.**
      await tags.insert(sampleTag(id: 'bare', colorHex: '#123456'));
      expect(
        await individuals.findByProject(projectId),
        isEmpty,
        reason: 'nothing may invent an animal for a collar',
      );
      final read = (await tags.findById('bare', projectId: projectId))!;
      expect(read.individualName, isNull);
      expect(
        read.colorHex,
        TagColorPalette.noIndividual,
        reason: 'not the seed colour, not the retired column — a constant',
      );
    });
  });

  group('colour has one home', () {
    test(
      'a tag reads its colour through its current deployment, and the retired '
      'column holds nothing',
      () async {
        await individuals.insert(
          sampleIndividual(id: 'marie', name: 'Marie', colorHex: '#111111'),
        );
        await tags.insert(sampleTag(id: 'tag-1', colorHex: '#999999'));
        await deployments.link(sampleDeployment(individualId: 'marie'));

        final raw = (await database.raw.query(Tables.tags)).single;
        expect(raw['color_hex'], isNull);
        final read = (await tags.findById('tag-1', projectId: projectId))!;
        expect(read.colorHex, '#111111');
        expect(read.individualName, 'Marie');
      },
    );

    test(
      'recolouring the animal recolours every collar she has worn, and '
      'nothing on the tag rows changed',
      () async {
        await individuals.insert(
          sampleIndividual(id: 'marie', colorHex: '#111111'),
        );
        await tags.insert(sampleTag(id: 'marie-2025'));
        await tags.insert(sampleTag(id: 'marie-2026'));
        // Sequential, not overlapping: the interlock forbids one animal
        // wearing two at once, which is the point of it. **The boundary is
        // one bare day apart, not the same one** — a same-day bare-day
        // handover genuinely overlaps under the no-tolerance rule (task
        // 11.263). Built through `deploymentDateFor` rather than a second
        // hand-written literal, so each end is a real bare day in whatever
        // zone reads it (task 11.276).
        await deployments.link(
          sampleDeployment(
            id: 'd1',
            tagId: 'marie-2025',
            individualId: 'marie',
            attachedDate: deploymentDateFor(DateTime.utc(2025, 1, 1)),
            removedDate: deploymentDateFor(DateTime.utc(2025, 12, 31)),
          ),
        );
        await deployments.link(
          sampleDeployment(
            id: 'd2',
            tagId: 'marie-2026',
            individualId: 'marie',
            attachedDate: deploymentDateFor(DateTime.utc(2026, 1, 1)),
          ),
        );
        final individual = (await individuals.findById(
          'marie',
          projectId: projectId,
        ))!;
        await individuals.update(
          individual.copyWith(colorHex: '#ABCDEF'),
          actor: actor,
        );

        final collars = {
          for (final t in await tags.findByProject(projectId))
            t.tagId: t.colorHex,
        };
        expect(
          collars.values.toSet(),
          {'#ABCDEF'},
          reason:
              'both are hers — a collar that came off is still her collar, '
              'which is a different question from what a bearing taken after '
              'it came off is about (that one is nobody). See '
              'DeploymentRepository.latestAnimalForTag.',
        );
        for (final raw in await database.raw.query(Tables.tags)) {
          expect(
            raw['color_hex'],
            isNull,
            reason: 'the mechanism, not a promise: the tag column is dead',
          );
        }
      },
    );

    test('recolouring through a tag edit lands on the animal wearing it',
        () async {
      await individuals.insert(
        sampleIndividual(id: 'marie', colorHex: '#111111'),
      );
      final stored = await tags.insert(sampleTag(id: 'tag-1'));
      await deployments.link(sampleDeployment(individualId: 'marie'));
      await tags.update(
        stored.copyWith(colorHex: '#222222'),
        actor: actor,
        intent: null,
      );
      final individual = (await individuals.findById(
        'marie',
        projectId: projectId,
      ))!;
      expect(individual.colorHex, '#222222');
    });

    test('recolouring a collar on nobody changes nothing and throws nothing',
        () async {
      // There is no animal to recolour. The edit is a no-op on the colour,
      // which is the honest answer rather than a refusal.
      final stored = await tags.insert(sampleTag(id: 'tag-1'));
      await tags.update(
        stored.copyWith(colorHex: '#222222'),
        actor: actor,
        intent: null,
      );
      expect(await individuals.findByProject(projectId), isEmpty);
      expect(
        (await tags.findById('tag-1', projectId: projectId))!.colorHex,
        TagColorPalette.noIndividual,
      );
    });
  });

  group("an individual's status is not the collar's", () {
    test('recovering a collar does not change the animal', () async {
      await individuals.insert(sampleIndividual(id: 'marie'));
      final stored = await tags.insert(sampleTag(id: 'tag-1'));
      await deployments.link(sampleDeployment(individualId: 'marie'));
      final animal = (await individuals.findById(
        'marie',
        projectId: projectId,
      ))!;
      await individuals.update(
        animal.copyWith(status: IndividualStatus.dead),
        actor: actor,
      );

      await tags.update(
        stored.copyWith(status: TagStatus.recovered),
        actor: actor,
        intent: null,
      );

      final after = (await individuals.findById(
        'marie',
        projectId: projectId,
      ))!;
      expect(
        after.status,
        IndividualStatus.dead,
        reason: 'a recovered collar must not make a dead animal read as alive',
      );
      expect(
        (await tags.findById('tag-1', projectId: projectId))!.status,
        TagStatus.recovered,
      );
    });

    test('unknown is one of the three, and it is the honest default', () {
      // Design §5. Michael added it on 2026-09-14 — and it was already there:
      // task 11.240 built the enum with it, so §5's "one addition" needed no
      // code. Asserted anyway, because the document says the app has it.
      expect(IndividualStatus.values.map((s) => s.db), [
        'alive',
        'dead',
        'unknown',
      ]);
    });

    test('the seed at creation is a default, and only at creation', () {
      expect(
        Individual.statusSeededFrom(TagStatus.active),
        IndividualStatus.alive,
      );
      for (final s in [
        TagStatus.recovered,
        TagStatus.lost,
        TagStatus.malfunction,
      ]) {
        expect(Individual.statusSeededFrom(s), IndividualStatus.unknown);
      }
    });
  });

  group('which animal wears a collar is its own dated act (task 11.243)', () {
    test('linking re-points the collar and writes nothing on the tag row',
        () async {
      final collar = await tags.insert(
        sampleTag(id: 'collar', tagName: 'Marie'),
      );
      await individuals.insert(
        sampleIndividual(id: 'marie', name: 'Marie', colorHex: '#ABCDEF'),
      );
      await deployments.link(
        sampleDeployment(tagId: 'collar', individualId: 'marie'),
      );

      final after = (await tags.findById('collar', projectId: projectId))!;
      expect(after.individualName, 'Marie', reason: 'read through the join');
      expect(after.colorHex, '#ABCDEF', reason: 'the colour follows the animal');
      expect(after.tagName, collar.tagName);
      expect(after.frequencyMhz, collar.frequencyMhz);
      expect(
        after.sync.revision,
        collar.sync.revision,
        reason: 'the tag row was not written at all — the link is its own row',
      );
      expect(
        await tags.findByIndividual('marie', projectId: projectId),
        hasLength(1),
      );
    });

    test('withdrawing the link makes the collar draw the neutral colour again',
        () async {
      await individuals.insert(sampleIndividual(id: 'marie'));
      await tags.insert(sampleTag(id: 'collar'));
      await deployments.link(
        sampleDeployment(id: 'd1', tagId: 'collar', individualId: 'marie'),
      );
      await deployments.unlink('d1', projectId: projectId, actor: actor);
      final after = (await tags.findById('collar', projectId: projectId))!;
      expect(after.individualName, isNull);
      expect(after.colorHex, TagColorPalette.noIndividual);
    });

    test(
      'reassigning a collar to a second animal the same day names the '
      'second, not the first — task 11.247, Michael, 2026-09-14',
      () async {
        // A same-day reassignment is the ordinary "recapture" shape §5a
        // describes: a collar comes off one animal and goes on another
        // inside one visit to the field, so both deployments end up
        // attached the same calendar day. `MAX(attached_date)` with a bare
        // column cannot tell them apart when they tie — this is watched
        // red against that regression, not merely asserted.
        //
        // **A bare day here is not a tie the interlock will allow** — since
        // task 11.263 two bare-day deployments overlapping on the same day
        // are refused outright, which is exactly what closing coco's link on
        // a bare "today" and opening kea's on the same bare "today" would
        // be. A real recapture records the swap's actual time (task 11.251,
        // design §4a); this fixture does the same, with an arbitrary but
        // fixed time so both rows still tie on the identical `attached_date`
        // value the MAX() comparison is about, rather than on the day.
        //
        // **Local noon, not UTC noon (task 11.326).** `DateTime.utc(…, 12, 0)`
        // is local midnight in any zone at UTC+12 — New Zealand's standard
        // time — and a midnight end reads as a bare day, so the interlock
        // refused the pair there. Noon on the device's own clock is a swap
        // time somebody could accept and is never midnight in any zone.
        final today = DateTime(2026, 9, 14, 12, 0);
        await individuals.insert(sampleIndividual(id: 'coco', name: 'Coco'));
        await individuals.insert(sampleIndividual(id: 'kea', name: 'Kea'));
        await tags.insert(sampleTag(id: 'collar'));

        await deployments.link(
          sampleDeployment(
            id: 'd-coco',
            tagId: 'collar',
            individualId: 'coco',
            attachedDate: today,
          ),
        );
        expect(
          (await tags.findById('collar', projectId: projectId))!.individualName,
          'Coco',
        );

        // Given a removed date today — not withdrawn — and linked to Kea,
        // also today: the ordinary "Set removed date" then "Link a tag"
        // sequence, which is what Michael's own description of the two
        // Animal screens after the fact matches (Coco's screen still lists
        // the collar, non-current; a withdrawn link would not be listed at
        // all). Both rows are now live, non-deleted, and share one
        // `attached_date` — the tie.
        final coco = (await deployments.findByIndividual('coco', projectId: projectId)).single;
        await deployments.update(
          coco.copyWith(removedDate: today),
          actor: actor,
          now: today,
        );
        await deployments.link(
          sampleDeployment(
            id: 'd-kea',
            tagId: 'collar',
            individualId: 'kea',
            attachedDate: today,
          ).copyWith(
            // A real device stamps this at the real instant the link is
            // written, which is necessarily later than Coco's original
            // link — `sampleDeployment`'s default `sync` is a fixture
            // constant and would tie the two rows on `created_at` as well
            // as on `attached_date`, which no real pair of writes ever
            // does.
            sync: SyncMeta.initial(now: today.add(const Duration(minutes: 5)), modifiedBy: 'user-1'),
          ),
        );

        final after = (await tags.findById('collar', projectId: projectId))!;
        expect(
          after.individualName,
          'Kea',
          reason: 'the more recently written deployment wins a tied date, '
              'not whichever the join happens to pick',
        );
        expect(
          await deployments.latestAnimalForTag('collar', projectId: projectId),
          'kea',
          reason: 'the Dart-side helper answers the same question and must '
              'agree with the SQL join',
        );
      },
    );

    test(
      'a contributor may record a collaring — it is not a change to the tag',
      () async {
        // **The rung moved with the column** (task 11.243). Writing
        // `Tags.individual_id` was a change to an existing tag and so was
        // owner-only; writing a `Deployments` row is an insert under the
        // ordinary gradient. The person holding the bird is the one who knows
        // which collar went on it.
        await UserRepository(
          database.raw,
        ).insert(sampleUser(id: 'user-2', email: 'c@x.com'));
        await database.raw.insert(
          Tables.projectMemberships,
          sampleMembership(
            id: 'm-2',
            userId: 'user-2',
            role: ProjectRole.contributor,
          ).toColumns(),
        );
        await tags.insert(sampleTag(id: 'collar', modifiedBy: 'user-2'));
        await individuals.insert(
          sampleIndividual(id: 'marie', modifiedBy: 'user-2'),
        );
        await deployments.link(
          sampleDeployment(
            tagId: 'collar',
            individualId: 'marie',
            modifiedBy: 'user-2',
          ),
        );
        expect(
          (await tags.findById('collar', projectId: projectId))!.individualName,
          'Marie',
        );
      },
    );

    test('a tag edit cannot unlink a collar, because it cannot express one',
        () async {
      // Task 11.240 had to strip `individual_id` out of the update's column
      // map by hand, because a stale `Tag` object carried a null. **`Tag` has
      // no such field now**, so the guarantee is structural rather than
      // remembered.
      expect(
        tableSpecsByName[Tables.tags]!.columnNames,
        isNot(contains('individual_id')),
      );
      await individuals.insert(sampleIndividual(id: 'marie'));
      final stale = sampleTag(id: 'collar', tagName: 'Marie');
      await tags.insert(stale);
      await deployments.link(
        sampleDeployment(tagId: 'collar', individualId: 'marie'),
      );
      await tags.update(
        stale.copyWith(notes: 'battery changed'),
        actor: actor,
        intent: null,
      );
      final after = (await tags.findById('collar', projectId: projectId))!;
      expect(after.notes, 'battery changed');
      expect(after.individualName, 'Marie');
    });
  });

  group('what must not change', () {
    test(
      'observations, sessions, estimates and truth points stay tag-scoped',
      () {
        // The load-bearing decision: you observed a signal from a
        // transmitter, not an animal. The animal is derived, so a mistake
        // about who wore what is corrected without touching a bearing.
        //
        // **`Tags` is on this list now too** (task 11.243). It was the one
        // exception at v16 and the exception is what the design withdrew: a
        // tag is equipment and names no animal either.
        for (final table in [
          Tables.observations,
          Tables.triangulationSessions,
          Tables.estimatedPositions,
          Tables.actualTagLocations,
          Tables.nonDetections,
          Tables.tagVersions,
          Tables.tags,
        ]) {
          expect(
            tableSpecsByName[table]!.columnNames,
            isNot(contains('individual_id')),
            reason: '$table must name a tag, never an animal',
          );
        }
        expect(
          tableSpecsByName[Tables.deployments]!.columnNames,
          contains('individual_id'),
          reason: 'exactly one table joins the two, and it carries dates',
        );
      },
    );

    test('the sealed columns still feed nothing, individuals included', () {
      expect(assertSealedColumnsFeedNoReachability, returnsNormally);
      expect(provenanceColumns[Tables.individuals], ['lineage_id', 'copied_at']);
      expect(
        syncTablesByName[Tables.individuals]!.tagColumns,
        isEmpty,
        reason: 'an individual never lists its collars',
      );
      expect(
        provenanceColumns[Tables.deployments],
        isNull,
        reason:
            'a deployment is a fact inside one project, so it has no lineage '
            'to seal — design §4',
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/individual_merge.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'fixtures.dart';

/// Task 11.241 — "these collars are the same animal", and what a person is
/// trusting when they press it.
///
/// The one assertion that matters most is the first group's: **the merge moves
/// no bearings.** Every observation is counted per collar and in total before
/// and after, and the counts must be identical. It was watched failing first
/// (the merge sabotaged to delete the absorbed collars' bearings, and again to
/// skip removed collars) before it was believed green.
void main() {
  late AppDatabase database;
  late TagRepository tags;
  late IndividualRepository individuals;
  late DeploymentRepository deployments;
  late ObservationRepository observations;
  late IndividualMerge merge;
  const projectId = 'project-1';
  final owner = MutationActor.user('user-1');

  /// Marie with two collars — 160.321 last season (removed from the project
  /// when it came off) and 160.523 this season — held as two animals, which
  /// is what the v16 backfill leaves behind. Plus Coco, an unrelated bird,
  /// as the control that must not move.
  late String marie2025;
  late String marie2026;
  late String coco;

  Future<Map<String, int>> observationCountsByTag() async {
    final rows = await observations.findByProject(projectId);
    final counts = <String, int>{};
    for (final o in rows) {
      counts[o.tagId!] = (counts[o.tagId!] ?? 0) + 1;
    }
    return counts;
  }

  setUp(() async {
    database = await AppDatabase.openInMemory();
    tags = TagRepository(database.raw);
    individuals = IndividualRepository(database.raw);
    deployments = DeploymentRepository(database.raw);
    observations = ObservationRepository(database.raw);
    merge = IndividualMerge(database.raw);
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject(id: projectId));
    await database.raw.insert(
      Tables.projectMemberships,
      sampleMembership(userId: 'user-1', role: ProjectRole.owner).toColumns(),
    );

    // **Task 11.243: the animals and the dated links are written out.** Each
    // `insert` used to create one animal per collar; a tag is equipment now
    // and creates nothing, so the fixture says what it means.
    marie2025 = 'marie-2025';
    marie2026 = 'marie-2026';
    coco = 'coco';
    for (final id in [marie2025, marie2026, coco]) {
      await individuals.insert(sampleIndividual(id: id, projectId: projectId));
    }
    for (final (id, freq) in [
      ('collar-2025', 160.321),
      ('collar-2025b', 160.322),
      ('collar-2026', 160.523),
      ('collar-coco', 150.100),
    ]) {
      await tags.insert(
        sampleTag(id: id, tagName: 'Marie', frequencyMhz: freq),
      );
    }
    // Last season's two collars on one animal, both ended; this season's on
    // the other. **Sequential, because the interlock forbids an animal
    // wearing two at once** — which is exactly the shape a real season has.
    //
    // **The boundary between d-2025 and d-2025b is one bare day apart, not
    // the same one.** A same-day bare-day handover is a genuine overlap
    // under the no-tolerance rule (task 11.263, `deployment_interlock.dart`)
    // — nothing about it is device behaviour, it is the ambiguous state the
    // rule exists to refuse. Built through `deploymentDateFor` rather than a
    // second hand-written literal, so each end is a real bare day in
    // whatever zone reads it, not a `DateTime.utc(...)` literal that only
    // happens to be one under this process's own zone (task 11.276).
    await deployments.link(
      sampleDeployment(
        id: 'd-2025',
        tagId: 'collar-2025',
        individualId: marie2025,
        attachedDate: deploymentDateFor(DateTime.utc(2025, 1, 1)),
        removedDate: deploymentDateFor(DateTime.utc(2025, 5, 31)),
      ),
    );
    await deployments.link(
      sampleDeployment(
        id: 'd-2025b',
        tagId: 'collar-2025b',
        individualId: marie2025,
        attachedDate: deploymentDateFor(DateTime.utc(2025, 6, 1)),
        removedDate: deploymentDateFor(DateTime.utc(2025, 12, 1)),
      ),
    );
    await deployments.link(
      sampleDeployment(
        id: 'd-2026',
        tagId: 'collar-2026',
        individualId: marie2026,
        attachedDate: DateTime.utc(2026, 1, 1),
      ),
    );
    await deployments.link(
      sampleDeployment(
        id: 'd-coco',
        tagId: 'collar-coco',
        individualId: coco,
        attachedDate: DateTime.utc(2026, 1, 1),
      ),
    );

    // Last season's collar came off and was removed from the project — a
    // tombstone on the tag row, exactly what "Remove from project" does.
    await tags.removeFromProject('collar-2025b', projectId: projectId, actor: owner);

    for (var i = 0; i < 3; i++) {
      await observations.insert(
        sampleObservation(id: 'old-$i', tagId: 'collar-2025', sessionId: null),
      );
    }
    await observations.insert(
      sampleObservation(id: 'spare-0', tagId: 'collar-2025b', sessionId: null),
    );
    for (var i = 0; i < 2; i++) {
      await observations.insert(
        sampleObservation(id: 'new-$i', tagId: 'collar-2026', sessionId: null),
      );
    }
    await observations.insert(
      sampleObservation(id: 'coco-0', tagId: 'collar-coco', sessionId: null),
    );
  });

  tearDown(() => database.close());

  group('merging animals moves no bearings', () {
    test('observation counts are identical before and after, per collar and '
        'in total', () async {
      final before = await observationCountsByTag();
      expect(before, {
        'collar-2025': 3,
        'collar-2025b': 1,
        'collar-2026': 2,
        'collar-coco': 1,
      });

      final moved = await merge.merge(
        projectId: projectId,
        keepId: marie2026,
        absorbId: marie2025,
        actor: owner,
      );
      expect(
        moved,
        2,
        reason: "both of last season's deployments, the removed collar's "
            'included',
      );

      final after = await observationCountsByTag();
      expect(after, before, reason: 'no bearing moved between collars');
      expect(
        after.values.fold<int>(0, (a, b) => a + b),
        before.values.fold<int>(0, (a, b) => a + b),
      );
      // And every row is the same row: ids, collars, versions untouched.
      final rows = await observations.findByProject(projectId);
      expect(rows.map((o) => o.observationId).toSet(),
          {'old-0', 'old-1', 'old-2', 'spare-0', 'new-0', 'new-1', 'coco-0'});
      expect(rows.every((o) => o.tagVersionId == 'tag-version-1'), isTrue);
    });
  });

  group('what the merge does', () {
    test("the absorbed animal's deployments name the kept one — the removed "
        'collar too', () async {
      await merge.merge(
        projectId: projectId,
        keepId: marie2026,
        absorbId: marie2025,
        actor: owner,
      );
      final hers = await tags.findByIndividual(marie2026, projectId: projectId);
      expect(hers.map((t) => t.tagId).toSet(), {
        'collar-2025',
        'collar-2025b',
        'collar-2026',
      });
      expect(
        (await deployments.findById('d-2025b', projectId: projectId))!
            .individualId,
        marie2026,
        reason:
            'a collar removed from the project was still worn by the animal',
      );
      expect(
        await deployments.findByIndividual(marie2025, projectId: projectId),
        isEmpty,
        reason: 'nothing is left naming the absorbed animal',
      );
    });

    test('the kept animal is untouched and the absorbed one is tombstoned', () async {
      final keptBefore = (await individuals.findById(marie2026, projectId: projectId))!;
      await individuals.update(keptBefore.copyWith(colorHex: '#ABCDEF'), actor: owner);
      final keptColoured = (await individuals.findById(marie2026, projectId: projectId))!;

      await merge.merge(
        projectId: projectId,
        keepId: marie2026,
        absorbId: marie2025,
        actor: owner,
      );

      final kept = (await individuals.findById(marie2026, projectId: projectId))!;
      expect(kept.name, keptColoured.name);
      expect(kept.colorHex, '#ABCDEF', reason: 'nothing of the other is copied on');
      expect(kept.status, keptColoured.status);
      expect(kept.sync.revision, keptColoured.sync.revision,
          reason: 'the kept row is not even written');

      expect(await individuals.findById(marie2025, projectId: projectId), isNull);
      final gone = await individuals.findById(marie2025, projectId: projectId, includeDeleted: true);
      expect(gone, isNotNull, reason: 'a tombstone, never a hard delete');
      expect(gone!.sync.isDeleted, isTrue);
      expect(await individuals.findByProject(projectId), hasLength(2),
          reason: 'Marie and Coco');
    });

    test('nothing about a collar changes except which animal it names', () async {
      final before = {
        for (final t in await tags.findByProject(projectId, includeDeleted: true))
          t.tagId: t,
      };
      Future<int> versionRows() async => (await database.raw.query(
            Tables.tagVersions,
            where: 'project_id = ?',
            whereArgs: [projectId],
          )).length;
      final versionsBefore = await versionRows();

      await merge.merge(
        projectId: projectId,
        keepId: marie2026,
        absorbId: marie2025,
        actor: owner,
      );

      for (final t in await tags.findByProject(projectId, includeDeleted: true)) {
        final was = before[t.tagId]!;
        expect(t.tagName, was.tagName);
        expect(t.frequencyMhz, was.frequencyMhz);
        expect(t.status, was.status);
        expect(
          t.sync.revision,
          was.sync.revision,
          reason:
              'the tag rows are not written at all now (task 11.243) — the '
              'merge re-points deployments',
        );
        expect(t.sync.isDeleted, was.sync.isDeleted,
            reason: 'a removed collar stays removed');
        expect(t.lineageId, was.lineageId);
      }
      // Every collar now reads the kept animal's colour, and no version row
      // was written: which animal wore it is not a measurement.
      expect(await versionRows(), versionsBefore);
      final marie = (await individuals.findById(
        marie2026,
        projectId: projectId,
      ))!;
      // Every collar she has worn draws her colour — the retired ones too,
      // because they are still hers (`latestAnimalForTag`).
      for (final t in await tags.findByIndividual(
        marie2026,
        projectId: projectId,
      )) {
        expect(t.colorHex, marie.colorHex, reason: t.tagId);
      }
    });

    test('the other animal is not involved', () async {
      await merge.merge(
        projectId: projectId,
        keepId: marie2026,
        absorbId: marie2025,
        actor: owner,
      );
      final cocosCollars = await tags.findByIndividual(
        coco,
        projectId: projectId,
      );
      expect(cocosCollars.map((t) => t.tagId), ['collar-coco']);
      expect(await individuals.findById(coco, projectId: projectId), isNotNull);
    });
  });

  group('what the merge refuses', () {
    test('a contributor, before anything is written', () async {
      final contributor = MutationActor.user('user-2');
      await UserRepository(database.raw).insert(sampleUser(id: 'user-2', email: 'c@x.com'));
      await database.raw.insert(
        Tables.projectMemberships,
        sampleMembership(id: 'm-2', userId: 'user-2', role: ProjectRole.contributor)
            .toColumns(),
      );
      await expectLater(
        merge.merge(
          projectId: projectId,
          keepId: marie2026,
          absorbId: marie2025,
          actor: contributor,
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await individuals.findByProject(projectId), hasLength(3));
      expect(
        (await deployments.findById('d-2025', projectId: projectId))!
            .individualId,
        marie2025,
        reason: 'refused before the first deployment moved',
      );
    });

    test('an animal merged into itself, and an animal that is not there', () async {
      await expectLater(
        merge.merge(projectId: projectId, keepId: marie2026, absorbId: marie2026, actor: owner),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        merge.merge(projectId: projectId, keepId: marie2026, absorbId: 'nobody', actor: owner),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        merge.merge(projectId: projectId, keepId: 'nobody', absorbId: marie2025, actor: owner),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

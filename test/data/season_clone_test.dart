import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/data_arrival.dart';
import 'package:tritrack/data/models/observation_exclusion.dart';
import 'package:tritrack/data/repositories/actual_tag_location_repository.dart';
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/estimated_position_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/season_clone.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/tag_version_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'fixtures.dart';

/// **Task 11.56: start next season from last season's project.**
///
/// The acceptance, in the plan's words: *what copies is derived from the
/// schema and stated table by table; no observation data crosses; people
/// join by their own action; and the tag-version question is answered with
/// a reason, not a default.* The first group is the derivation; the rest
/// check the clone against it row by row.
///
/// **The source is seeded with a row in every synced table** — including
/// the ones that must not cross — because a test whose source holds nothing
/// in `Observations` proves nothing about observations not copying.
void main() {
  late AppDatabase database;
  late SeasonClone cloner;

  const source = 'ponui-2025';
  const other = 'somebody-elses-project';
  const creator = 'user-1';
  const teammate = 'user-2';
  final at = DateTime.utc(2026, 9, 15, 10);
  DateTime d(int day) => DateTime(2026, 3, day);

  Future<int> count(String table, String projectId) async {
    final rows = await database.raw.rawQuery(
      'SELECT count(*) AS n FROM $table '
      'WHERE project_id = ? AND deleted_at IS NULL',
      [projectId],
    );
    return rows.single['n']! as int;
  }

  Future<List<Map<String, Object?>>> rowsOf(String table, String projectId) =>
      database.raw.query(
        table,
        where: 'project_id = ? AND deleted_at IS NULL',
        whereArgs: [projectId],
      );

  setUp(() async {
    database = await AppDatabase.openInMemory();
    cloner = SeasonClone(database.raw);
    final db = database.raw;
    // Raw inserts, on purpose: the fixture is a season as it exists on a
    // phone after a sync, not one built through the screens, so no
    // repository's authorization is in the way of seeding it.
    await db.insert(Tables.users, sampleUser(id: creator).toColumns());
    await db.insert(
      Tables.users,
      sampleUser(id: teammate, email: 'tech@example.com').toColumns(),
    );
    await db.insert(
      Tables.userEmails,
      sampleUserEmail(userId: creator).toColumns(),
    );
    await db.insert(
      Tables.projects,
      sampleProject(id: source, ownerUserId: teammate).toColumns(),
    );
    // A second project on the device, untouched throughout: a clone that
    // read "every tag on this device" rather than "every tag of the source"
    // would carry its rows across.
    await db.insert(
      Tables.projects,
      sampleProject(id: other, ownerUserId: teammate).toColumns(),
    );
    await db.insert(
      Tables.tags,
      sampleTag(
        id: 'other-tag',
        projectId: other,
        tagName: 'Not ours',
      ).toColumns(),
    );
    // Two members: the teammate owns it, the creator is a viewer — the
    // weakest role, so the test also says a viewer may start a season.
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'm-owner',
        projectId: source,
        userId: teammate,
      ).toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'm-viewer',
        projectId: source,
        userId: creator,
        role: ProjectRole.viewer,
      ).toColumns(),
    );
    // Three animals: alive, dead, and one whose row was deleted.
    await db.insert(
      Tables.individuals,
      sampleIndividual(
        id: 'marie',
        projectId: source,
        name: 'Marie',
        lineageId: 'lineage-marie',
      ).toColumns(),
    );
    await db.insert(
      Tables.individuals,
      sampleIndividual(
        id: 'kea',
        projectId: source,
        name: 'Kea',
        status: IndividualStatus.dead,
        lineageId: 'lineage-kea',
      ).toColumns(),
    );
    await db.insert(
      Tables.individuals,
      sampleIndividual(
        id: 'gone',
        projectId: source,
        name: 'Gone',
      ).copyWith(sync: sampleSync().copyWith(deletedAt: at)).toColumns(),
    );
    // Three collars: two live, one removed from the project.
    await db.insert(
      Tables.tags,
      sampleTag(
        id: 'collar-a',
        projectId: source,
        tagName: 'A',
        lineageId: 'lineage-a',
        frequencyMhz: 150.1,
      ).toColumns(),
    );
    await db.insert(
      Tables.tags,
      sampleTag(
        id: 'collar-b',
        projectId: source,
        tagName: 'B',
        lineageId: 'lineage-b',
        frequencyMhz: 150.2,
      ).toColumns(),
    );
    await db.insert(
      Tables.tags,
      sampleTag(
        id: 'collar-gone',
        projectId: source,
        tagName: 'Gone',
      ).copyWith(sync: sampleSync().copyWith(deletedAt: at)).toColumns(),
    );
    // Collar A has a two-row history in the source: created, then re-tuned.
    await db.insert(
      Tables.tagVersions,
      sampleTagVersion(
        id: 'a-v1',
        projectId: source,
        tagId: 'collar-a',
        frequencyMhz: 150.0,
        effectiveFrom: d(1),
      ).toColumns(),
    );
    await db.insert(
      Tables.tagVersions,
      sampleTagVersion(
        id: 'a-v2',
        projectId: source,
        tagId: 'collar-a',
        frequencyMhz: 150.1,
        effectiveFrom: d(5),
      ).toColumns(),
    );
    await db.insert(
      Tables.tagVersions,
      sampleTagVersion(
        id: 'b-v1',
        projectId: source,
        tagId: 'collar-b',
      ).toColumns(),
    );
    // Four links: A on Marie (closed), B on Kea (open, and Kea is dead),
    // the deleted collar on Marie, and A on the deleted animal.
    await db.insert(
      Tables.deployments,
      sampleDeployment(
        id: 'a-on-marie',
        projectId: source,
        tagId: 'collar-a',
        individualId: 'marie',
        attachedDate: d(1),
        removedDate: d(10),
      ).toColumns(),
    );
    await db.insert(
      Tables.deployments,
      sampleDeployment(
        id: 'b-on-kea',
        projectId: source,
        tagId: 'collar-b',
        individualId: 'kea',
        attachedDate: d(2),
      ).toColumns(),
    );
    await db.insert(
      Tables.deployments,
      sampleDeployment(
        id: 'gone-on-marie',
        projectId: source,
        tagId: 'collar-gone',
        individualId: 'marie',
        attachedDate: d(12),
      ).toColumns(),
    );
    await db.insert(
      Tables.deployments,
      sampleDeployment(
        id: 'a-on-gone',
        projectId: source,
        tagId: 'collar-a',
        individualId: 'gone',
        attachedDate: d(20),
      ).toColumns(),
    );
    // Last season's observations — every kind.
    await db.insert(
      Tables.triangulationSessions,
      sampleSession(id: 's1', projectId: source, tagId: 'collar-a').toColumns(),
    );
    await db.insert(
      Tables.observations,
      sampleObservation(
        id: 'obs-1',
        projectId: source,
        userId: teammate,
        tagId: 'collar-a',
        sessionId: 's1',
        tagVersionId: 'a-v2',
      ).toColumns(),
    );
    await db.insert(
      Tables.observationExclusions,
      ObservationExclusion(
        exclusionId: 'x1',
        projectId: source,
        observationId: 'obs-1',
        userId: teammate,
        kind: ObservationExclusionKind.superseded,
        sync: sampleSync(),
      ).toColumns(),
    );
    await db.insert(
      Tables.nonDetections,
      sampleNonDetection(
        id: 'nd-1',
        projectId: source,
        userId: teammate,
      ).toColumns(),
    );
    await db.insert(
      Tables.estimatedPositions,
      sampleEstimatedPosition(
        id: 'est-1',
        projectId: source,
        tagId: 'collar-a',
      ).toColumns(),
    );
    await db.insert(
      Tables.actualTagLocations,
      sampleActualLocation(
        id: 'loc-1',
        projectId: source,
        tagId: 'collar-a',
        tagVersionId: 'a-v2',
      ).toColumns(),
    );
    // Where each animal was last. The fixture's default moment (July) falls
    // in the deleted animal's open deployment of collar A, so `est-1` and
    // `loc-1` above belong to nobody the clone copies. These four have real
    // moments inside real deployments — except the one on day 1, when
    // collar B was on nobody yet.
    for (final (id, tag, day, used) in [
      ('est-marie-old', 'collar-a', 3, ['obs-old-1', 'obs-old-2']),
      ('est-marie-new', 'collar-a', 8, ['obs-1', 'obs-2', 'obs-3']),
      ('est-nobody', 'collar-b', 1, ['obs-x']),
    ]) {
      await db.insert(
        Tables.estimatedPositions,
        sampleEstimatedPosition(id: id, projectId: source, tagId: tag)
            .copyWith(
              timestampLocal: d(day),
              timestampUtc: d(day).toUtc(),
              observationIdsUsed: used,
            )
            .toColumns(),
      );
    }
    for (final (id, tag, day, finder) in [
      ('loc-marie', 'collar-a', 9, teammate),
      ('loc-kea', 'collar-b', 15, creator),
    ]) {
      await db.insert(
        Tables.actualTagLocations,
        sampleActualLocation(
              id: id,
              projectId: source,
              tagId: tag,
              tagVersionId: tag == 'collar-a' ? 'a-v2' : 'b-v1',
              userId: finder,
            )
            .copyWith(timestampLocal: d(day), timestampUtc: d(day).toUtc())
            .toColumns(),
      );
    }
  });

  tearDown(() => database.close());

  group('the table-by-table statement is derived from the schema', () {
    test('every synced table has a disposition, and nothing else does', () {
      expect(seasonCloneDispositions.keys, unorderedEquals(Tables.all));
    });

    test('"global" is exactly the tables with no project column', () {
      for (final table in Tables.all) {
        final global = syncTablesByName[table]!.projectScopeColumn == null;
        expect(
          seasonCloneDispositions[table] == SeasonCloneDisposition.global,
          global,
          reason: table,
        );
      }
    });

    test('every table in the source holds a row, so each disposition is '
        'tested against something', () async {
      for (final table in Tables.all) {
        if (seasonCloneDispositions[table] == SeasonCloneDisposition.global) {
          continue;
        }
        expect(await count(table, source), greaterThan(0), reason: table);
      }
    });
  });

  group('what the clone writes, checked against the statement', () {
    late SeasonCloneResult result;
    late String season;

    setUp(() async {
      result = await cloner.clone(
        sourceProjectId: source,
        name: 'Ponui 2026',
        creatorUserId: creator,
        includeAnimalsRecordedDead: true,
        includeLastKnownPositions: false,
        deviceId: 'device-A',
        now: at,
      );
      season = result.project.projectId;
    });

    test('each disposition holds, table by table', () async {
      for (final entry in seasonCloneDispositions.entries) {
        final table = entry.key;
        if (entry.value == SeasonCloneDisposition.global) continue;
        final n = await count(table, season);
        switch (entry.value) {
          case SeasonCloneDisposition.global:
            break;
          case SeasonCloneDisposition.theProject:
            expect(n, 1, reason: table);
          case SeasonCloneDisposition.creatorOnly:
            expect(n, 1, reason: table);
          case SeasonCloneDisposition.copied:
            expect(n, await count(table, source), reason: table);
          case SeasonCloneDisposition.copiedIfBothEndsWere:
            // Four in the source; two name a deleted collar or animal.
            expect(n, 2, reason: table);
          case SeasonCloneDisposition.freshHistory:
            // One per copied collar — not the source's three.
            expect(n, await count(Tables.tags, season), reason: table);
          case SeasonCloneDisposition.notCopied:
            expect(n, 0, reason: '$table must not cross seasons');
          case SeasonCloneDisposition.lastKnownPerAnimal:
            // This group clones with `includeLastKnownPositions: false`.
            expect(n, 0, reason: '$table crosses only when asked');
        }
      }
    });

    test('no observation data crosses — said again by name, because it is '
        'the point', () async {
      for (final table in [
        Tables.observations,
        Tables.nonDetections,
        Tables.estimatedPositions,
        Tables.actualTagLocations,
        Tables.triangulationSessions,
        Tables.observationExclusions,
      ]) {
        expect(await count(table, season), 0, reason: table);
      }
    });

    test('the creator is the only member, and is the owner', () async {
      final members = await rowsOf(Tables.projectMemberships, season);
      expect(members, hasLength(1));
      expect(members.single['user_id'], creator);
      expect(members.single['role'], ProjectRole.owner.db);
      expect(members.single['end_date'], isNull);
      expect(result.project.ownerUserId, creator);
    });

    test('the project carries the study area and settings, a fresh id, and '
        'the source\'s lineage', () async {
      final src = (await ProjectRepository(database.raw).findById(source))!;
      final p = result.project;
      expect(p.projectId, isNot(source));
      expect(p.projectName, 'Ponui 2026');
      expect(p.description, src.description);
      expect(p.notes, src.notes);
      expect(p.bboxMinLat, src.bboxMinLat);
      expect(p.bboxMaxLon, src.bboxMaxLon);
      expect(p.coordinateFormat, src.coordinateFormat);
      expect(p.triangulationWindowMinutes, src.triangulationWindowMinutes);
      expect(p.creationDate, at);
      // The source predates v18's lineage in this fixture (null), and its
      // effective lineage is its own id — which the copy carries.
      expect(src.lineageId, isNull);
      expect(p.lineageId, source);
      expect(p.copiedAt, at);
      // And it is stored, not only returned.
      final stored = (await ProjectRepository(database.raw).findById(season))!;
      expect(stored.lineageId, source);
      expect(stored.copiedAt, at);
    });

    test('a season started from a season carries the first project\'s '
        'lineage, not the middle one\'s', () async {
      final third = await cloner.clone(
        sourceProjectId: season,
        name: 'Ponui 2027',
        creatorUserId: creator,
        includeAnimalsRecordedDead: true,
        includeLastKnownPositions: false,
        now: at.add(const Duration(days: 365)),
      );
      expect(third.project.lineageId, source);
    });

    test('every copied animal and collar keeps its lineage, takes a fresh id, '
        'and is stamped copied_at', () async {
      final animals = await IndividualRepository(
        database.raw,
      ).findByProject(season);
      expect(
        {for (final a in animals) a.lineageId},
        {'lineage-marie', 'lineage-kea'},
      );
      for (final a in animals) {
        expect(a.individualId, isNot(anyOf('marie', 'kea')));
        expect(a.copiedAt, at);
      }
      final collars = await TagRepository(database.raw).findByProject(season);
      expect(
        {for (final c in collars) c.lineageId},
        {'lineage-a', 'lineage-b'},
      );
      for (final c in collars) {
        expect(c.tagId, isNot(anyOf('collar-a', 'collar-b')));
        expect(c.copiedAt, at);
      }
      expect(result.animals, 2);
      expect(result.collars, 2);
    });

    test(
      'a dead bird copies as dead — it does not come back to life',
      () async {
        final animals = await IndividualRepository(
          database.raw,
        ).findByProject(season);
        final kea = animals.singleWhere((a) => a.name == 'Kea');
        expect(kea.status, IndividualStatus.dead);
      },
    );

    test('every copied deployment has BOTH ends in the new project — none '
        'spans two projects', () async {
      final links = await DeploymentRepository(
        database.raw,
      ).findByProject(season);
      expect(links, hasLength(2));
      final seasonTags = {
        for (final r in await rowsOf(Tables.tags, season)) r['tag_id'],
      };
      final seasonAnimals = {
        for (final r in await rowsOf(Tables.individuals, season))
          r['individual_id'],
      };
      for (final link in links) {
        expect(seasonTags, contains(link.tagId), reason: 'tag end');
        expect(
          seasonAnimals,
          contains(link.individualId),
          reason: 'animal end',
        );
        // And neither end is a source id, which is the other way a link can
        // span two projects when ids happen to be shared across them.
        expect(link.tagId, isNot(anyOf('collar-a', 'collar-b')));
        expect(link.individualId, isNot(anyOf('marie', 'kea')));
      }
      expect(result.collarRecords, 2);
    });

    test('the dates on a copied deployment are carried unchanged', () async {
      final links = await DeploymentRepository(
        database.raw,
      ).findByProject(season);
      // Stored and read back as UTC; the fixture's days are local midnights.
      final byAttached = {for (final l in links) l.attachedDate: l};
      expect(byAttached.keys, unorderedEquals([d(1).toUtc(), d(2).toUtc()]));
      expect(byAttached[d(1).toUtc()]!.removedDate, d(10).toUtc());
      expect(byAttached[d(2).toUtc()]!.removedDate, isNull);
    });

    test('the tag-version question: a copied collar starts a fresh history '
        'whose first version reads what the collar reads today', () async {
      final versions = TagVersionRepository(database.raw);
      final collars = await TagRepository(database.raw).findByProject(season);
      for (final c in collars) {
        final current = (await versions.currentFor(c.tagId))!;
        expect(current.projectId, season);
        expect(current.tagId, c.tagId);
        expect(current.frequencyMhz, c.frequencyMhz);
        expect(current.effectiveFrom, at);
        // Not one of the source's rows re-pointed.
        expect(current.tagVersionId, isNot(anyOf('a-v1', 'a-v2', 'b-v1')));
      }
      // Collar A had two versions in the source; its copy has one.
      final a = collars.singleWhere((c) => c.tagName == 'A');
      expect(
        await database.raw.query(
          Tables.tagVersions,
          where: 'tag_id = ? AND project_id = ?',
          whereArgs: [a.tagId, season],
        ),
        hasLength(1),
      );
      // And the source's history is exactly as it was.
      expect(await count(Tables.tagVersions, source), 3);
    });

    test('the source is untouched, and so is the other project', () async {
      for (final table in Tables.all) {
        if (seasonCloneDispositions[table] == SeasonCloneDisposition.global) {
          continue;
        }
        final rows = await rowsOf(table, source);
        for (final row in rows) {
          expect(
            row['updated_at'],
            DbCodec.encodeUtc(sampleSync().updatedAt),
            reason: '$table row ${row.values.first} was modified',
          );
        }
      }
      expect(await count(Tables.tags, other), 1);
      expect(await count(Tables.tags, season), 2);
    });

    test('the copies read as copies, not as originals: nothing in the new '
        'season carries a source id', () async {
      final sourceIds = <Object?>{};
      for (final table in Tables.all) {
        if (seasonCloneDispositions[table] == SeasonCloneDisposition.global) {
          continue;
        }
        for (final row in await rowsOf(table, source)) {
          sourceIds.add(row.values.first);
        }
      }
      for (final table in Tables.all) {
        if (seasonCloneDispositions[table] == SeasonCloneDisposition.global) {
          continue;
        }
        for (final row in await rowsOf(table, season)) {
          expect(sourceIds, isNot(contains(row.values.first)), reason: table);
        }
      }
    });
  });

  group('leaving the dead behind', () {
    test(
      'the dead animal and the link on it are not copied; the live one is',
      () async {
        final result = await cloner.clone(
          sourceProjectId: source,
          name: 'Ponui 2026',
          creatorUserId: creator,
          includeAnimalsRecordedDead: false,
          includeLastKnownPositions: false,
          now: at,
        );
        final season = result.project.projectId;
        final animals = await IndividualRepository(
          database.raw,
        ).findByProject(season);
        expect(animals.map((a) => a.name), ['Marie']);
        // Collar B still copies — it is equipment, and the bird it was on
        // being left behind does not make the collar disappear.
        expect(await count(Tables.tags, season), 2);
        final links = await DeploymentRepository(
          database.raw,
        ).findByProject(season);
        expect(links, hasLength(1));
        expect(links.single.attachedDate, d(1).toUtc());
        expect(result.animals, 1);
        expect(result.collarRecords, 1);
      },
    );
  });

  group('bringing over where each animal was last (Michael, 2026-09-16)', () {
    Future<SeasonCloneResult> cloneWithPositions({bool dead = true}) =>
        cloner.clone(
          sourceProjectId: source,
          name: 'Ponui 2026',
          creatorUserId: creator,
          includeAnimalsRecordedDead: dead,
          includeLastKnownPositions: true,
          now: at,
        );

    test('one estimate per animal — the most recent, attributed by who wore '
        'the collar then — re-pointed at the new collar, bearings list '
        'carried', () async {
      final result = await cloneWithPositions();
      final season = result.project.projectId;
      final estimates = await EstimatedPositionRepository(
        database.raw,
      ).findByProject(season);
      // Marie's newest of two; not the day-1 one on a collar nobody wore;
      // not the July one on the deleted animal's collar.
      expect(estimates, hasLength(1));
      final marie = estimates.single;
      expect(marie.timestampUtc, d(8).toUtc());
      expect(marie.observationIdsUsed, ['obs-1', 'obs-2', 'obs-3']);
      expect(marie.positionId, isNot('est-marie-new'));
      final newCollarA = (await TagRepository(
        database.raw,
      ).findByProject(season)).singleWhere((t) => t.tagName == 'A');
      expect(marie.tagId, newCollarA.tagId);
      expect(result.lastKnownEstimates, 1);
      // The source still has all four.
      expect(await count(Tables.estimatedPositions, source), 4);
    });

    test('one truth point per animal; the finder is kept only when it is the '
        'person cloning, and the tag-version pointer is not carried', () async {
      final result = await cloneWithPositions();
      final season = result.project.projectId;
      final points = await ActualTagLocationRepository(
        database.raw,
      ).findByProject(season);
      expect(points, hasLength(2));
      final byDay = {for (final p in points) p.timestampUtc: p};
      final marie = byDay[d(9).toUtc()]!;
      final kea = byDay[d(15).toUtc()]!;
      // The teammate found Marie's; the server would refuse a new row
      // naming them, so the copy names nobody.
      expect(marie.userId, isNull);
      // The creator found Kea's, and may say so.
      expect(kea.userId, creator);
      for (final p in points) {
        expect(p.tagVersionId, isNull);
        expect(p.locationId, isNot(anyOf('loc-1', 'loc-marie', 'loc-kea')));
      }
      expect(result.lastKnownTruthPoints, 2);
      expect(await count(Tables.actualTagLocations, source), 3);
    });

    test('an animal left behind takes its last position with it', () async {
      final result = await cloneWithPositions(dead: false);
      final season = result.project.projectId;
      expect(await count(Tables.actualTagLocations, season), 1);
      expect(result.lastKnownTruthPoints, 1);
    });

    test(
      'nothing else from the observation tables crosses even then',
      () async {
        final season = (await cloneWithPositions()).project.projectId;
        for (final table in [
          Tables.observations,
          Tables.nonDetections,
          Tables.triangulationSessions,
          Tables.observationExclusions,
        ]) {
          expect(await count(table, season), 0, reason: table);
        }
      },
    );
  });

  group('the plan counts what the clone will do, before it does it', () {
    test('counts', () async {
      final plan = await cloner.plan(source);
      expect(plan.source.projectId, source);
      expect(plan.animals, 2);
      expect(plan.animalsRecordedDead, 1);
      expect(plan.collars, 2);
      expect(plan.collarRecords, 2);
      expect(plan.collarRecordsWithoutBothEnds, 2);
      expect(plan.lastKnownEstimates, 1);
      expect(plan.lastKnownTruthPoints, 2);
      // Writing nothing.
      expect(await ProjectRepository(database.raw).findAll(), hasLength(2));
    });

    test('a missing source is a screen mistake', () async {
      expect(() => cloner.plan('nope'), throwsArgumentError);
      expect(
        () => cloner.clone(
          sourceProjectId: 'nope',
          name: 'x',
          creatorUserId: creator,
          includeAnimalsRecordedDead: true,
          includeLastKnownPositions: false,
        ),
        throwsArgumentError,
      );
    });

    test('an empty name is refused before anything is written', () async {
      await expectLater(
        cloner.clone(
          sourceProjectId: source,
          name: '   ',
          creatorUserId: creator,
          includeAnimalsRecordedDead: true,
          includeLastKnownPositions: false,
        ),
        throwsArgumentError,
      );
      expect(await ProjectRepository(database.raw).findAll(), hasLength(2));
    });
  });

  group('one transaction, one announcement', () {
    test('a failure part-way leaves nothing behind', () async {
      // Make the last step fail: a source link whose copy the interlock
      // refuses. Collar B is on Kea open-ended from day 2; a second open
      // link of B on Marie from day 3 overlaps it. Seeded raw, so the source
      // holds a pair its own screens would have refused.
      await database.raw.insert(
        Tables.deployments,
        sampleDeployment(
          id: 'b-on-marie-too',
          projectId: source,
          tagId: 'collar-b',
          individualId: 'marie',
          attachedDate: d(3),
        ).toColumns(),
      );
      await expectLater(
        cloner.clone(
          sourceProjectId: source,
          name: 'Ponui 2026',
          creatorUserId: creator,
          includeAnimalsRecordedDead: true,
          includeLastKnownPositions: false,
          now: at,
        ),
        throwsA(isA<OverlappingDeployment>()),
      );
      // Not a project with half its animals in it.
      expect(await ProjectRepository(database.raw).findAll(), hasLength(2));
      expect(
        await database.raw.query(
          Tables.individuals,
          where: 'project_id NOT IN (?, ?)',
          whereArgs: [source, other],
        ),
        isEmpty,
      );
    });

    test('the clone announces once, after it is committed', () async {
      var announced = 0;
      void listener() => announced += 1;
      DataArrival.addListener(listener);
      addTearDown(() => DataArrival.removeListener(listener));
      await cloner.clone(
        sourceProjectId: source,
        name: 'Ponui 2026',
        creatorUserId: creator,
        includeAnimalsRecordedDead: true,
        includeLastKnownPositions: false,
        now: at,
      );
      expect(announced, 1);
    });
  });
}

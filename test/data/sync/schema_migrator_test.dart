import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/data/sync/schema_migrator.dart';

import '../fixtures.dart';
import 'backup_builders.dart';

void main() {
  v15RelinkTests();
  group('SchemaMigrator', () {
    test('v1 backup gains the v2 Projects columns with their defaults', () {
      // A v1 project row lacks the two v2 columns.
      final projectRow = sampleProject().toColumns()
        ..remove('coordinate_format')
        ..remove('triangulation_window_minutes');
      final backup = makeBackup(
        {Tables.projects: [projectRow]},
        schemaVersion: 1,
      );

      final from = SchemaMigrator.migrateToCurrent(backup);

      expect(from, 1);
      final migrated = backup.rowsFor(Tables.projects).single;
      expect(migrated['coordinate_format'], 'dd');
      expect(migrated['triangulation_window_minutes'], 15);
    });

    test('a current-version backup is left untouched', () {
      final row = sampleProject().toColumns();
      final backup = makeBackup({Tables.projects: [row]},
          schemaVersion: latestSchemaVersion);
      final from = SchemaMigrator.migrateToCurrent(backup);
      expect(from, latestSchemaVersion);
      expect(backup.rowsFor(Tables.projects).single['coordinate_format'],
          row['coordinate_format']);
    });

    test('a v1 backup that already has the columns is not overwritten', () {
      final row = sampleProject().toColumns()..['coordinate_format'] = 'utm';
      final backup = makeBackup({Tables.projects: [row]}, schemaVersion: 1);
      SchemaMigrator.migrateToCurrent(backup);
      expect(backup.rowsFor(Tables.projects).single['coordinate_format'], 'utm');
    });

    test('a backup on a newer schema MAJOR is refused', () {
      final backup = makeBackup({}, schemaMajor: schemaMajorVersion + 1);
      expect(() => SchemaMigrator.migrateToCurrent(backup),
          throwsA(isA<SchemaTooNewException>()));
    });

    test('a backup on an older schema MAJOR migrates forward, not refused', () {
      // Deliberately asymmetric with the wire, which refuses any major
      // mismatch in either direction (`SyncEnvelope.fromJson`). Reading an
      // archive is one-way and settled, and task 10.35's acceptance criterion
      // is that "every existing backup archive has to remain readable" — the
      // major-2 re-key derives `(<id>, project_id)` from a column every one of
      // those rows already carried, so the crossing invents nothing.
      final projectRow = sampleProject().toColumns();
      final observationRow = sampleObservation().toColumns();
      final backup = makeBackup(
        {
          Tables.projects: [projectRow],
          Tables.observations: [observationRow],
        },
        schemaMajor: schemaMajorVersion - 1,
        schemaVersion: latestSchemaVersion - 1,
      );

      expect(SchemaMigrator.migrateToCurrent(backup), latestSchemaVersion - 1);
      // Both halves of the new key survived the crossing, from the row's own
      // data rather than from a default.
      final migrated = backup.rowsFor(Tables.observations).single;
      expect(migrated['observation_id'], observationRow['observation_id']);
      expect(migrated['project_id'], observationRow['project_id']);
    });

    test('a backup on a newer MINOR is accepted, columns and all', () {
      // Task 10.18: the extra columns of a newer minor are not dropped here.
      // They travel on into the merge, which holds them verbatim. Dropping them
      // is precisely the destruction the old exact-equality rule existed to
      // prevent, and refusing the whole backup was too blunt a way to avoid it.
      final row = sampleProject().toColumns()..['future_column'] = 'keep me';
      final backup = makeBackup(
        {Tables.projects: [row]},
        schemaVersion: latestSchemaVersion + 1,
      );

      final from = SchemaMigrator.migrateToCurrent(backup);

      expect(from, latestSchemaVersion + 1);
      expect(backup.rowsFor(Tables.projects).single['future_column'], 'keep me');
    });

    test('a v1 backup gains distinct round-robin colors for existing tags', () {
      final tagRows = [
        sampleTag(id: 'tag-1').toColumns()..remove('color_hex'),
        sampleTag(id: 'tag-2').toColumns()..remove('color_hex'),
        sampleTag(id: 'tag-3').toColumns()..remove('color_hex'),
      ];
      final backup = makeBackup({Tables.tags: tagRows}, schemaVersion: 1);

      SchemaMigrator.migrateToCurrent(backup);

      // v4 backfilled the tag's colour; v16 (task 11.240) moved every tag's
      // colour onto the individual it created for that tag and nulled the
      // tag's, so the colours are read where they now live.
      final colors =
          backup.rowsFor(Tables.individuals).map((r) => r['color_hex']).toList();
      expect(colors, [
        TagColorPalette.colors[0],
        TagColorPalette.colors[1],
        TagColorPalette.colors[2],
      ]);
      expect(colors.toSet(), hasLength(3), reason: 'backfilled colors must be distinct');
      expect(
        backup.rowsFor(Tables.tags).map((r) => r['color_hex']),
        everyElement(isNull),
        reason: 'the retired column carries nothing after v16',
      );
    });

    test('a backup that already has color_hex is not overwritten', () {
      final row = sampleTag().toColumns()..['color_hex'] = '#123456';
      final backup = makeBackup({Tables.tags: [row]}, schemaVersion: 1);
      SchemaMigrator.migrateToCurrent(backup);
      // The colour survives v4 untouched and v16 moves it, verbatim, onto
      // the tag's individual.
      expect(backup.rowsFor(Tables.individuals).single['color_hex'], '#123456');
      expect(backup.rowsFor(Tables.tags).single['color_hex'], isNull);
    });

    group('v16 (task 11.240): one individual per tag, keyed by the tag', () {
      test('every tag gets its own animal, named after it, linked back', () {
        final rows = [
          sampleTag(id: 'tag-1').toColumns()
            ..['tag_name'] = 'Marie'
            ..['color_hex'] = '#111111'
            ..['individual_id'] = null,
          sampleTag(id: 'tag-2').toColumns()
            ..['tag_name'] = 'Coco'
            ..['status'] = TagStatus.recovered.db
            ..['individual_id'] = null,
        ];
        final backup = makeBackup({Tables.tags: rows}, schemaVersion: 15);
        SchemaMigrator.migrateToCurrent(backup);

        final individuals = backup.rowsFor(Tables.individuals);
        expect(individuals, hasLength(2));
        final marie = individuals.singleWhere((i) => i['name'] == 'Marie');
        expect(marie['individual_id'], 'tag-1');
        expect(marie['project_id'], rows[0]['project_id']);
        expect(marie['color_hex'], '#111111');
        expect(marie['lineage_id'], 'tag-1', reason: 'its own id: nothing copied');
        expect(marie['copied_at'], isNull);
        expect(marie['status'], IndividualStatus.alive.db);
        final coco = individuals.singleWhere((i) => i['name'] == 'Coco');
        expect(
          coco['status'],
          IndividualStatus.unknown.db,
          reason: 'a recovered collar says nothing about the bird',
        );
        for (final tag in backup.rowsFor(Tables.tags)) {
          expect(tag['color_hex'], isNull);
          // **v16 linked the tag to the animal it made; v17 takes the column
          // off again** (task 11.243). Both steps run on the way to the
          // current version, so what a caller sees at the end is the animals
          // and no link — which is exactly what the device's own migrations
          // leave behind, and that agreement is the property that matters.
          expect(
            tag.containsKey('individual_id'),
            isFalse,
            reason: 'a tag names no animal at schema v17',
          );
        }
      });

      test('two tags with the same name stay two animals — no name-matching',
          () {
        // The claim the migration refuses to make: two collars labelled
        // "Marie" may be one bird, a reused name, or a colliding typo.
        final rows = [
          sampleTag(id: 'tag-1').toColumns()
            ..['tag_name'] = 'Marie'
            ..['individual_id'] = null,
          sampleTag(id: 'tag-2').toColumns()
            ..['tag_name'] = 'Marie'
            ..['individual_id'] = null,
        ];
        final backup = makeBackup({Tables.tags: rows}, schemaVersion: 15);
        SchemaMigrator.migrateToCurrent(backup);
        final individuals = backup.rowsFor(Tables.individuals);
        expect(individuals, hasLength(2));
        expect(
          individuals.map((i) => i['individual_id']).toSet(),
          {'tag-1', 'tag-2'},
        );
        expect(
          individuals.map((i) => i['lineage_id']).toSet(),
          hasLength(2),
          reason: 'and not the same animal by lineage either',
        );
      });

      test('a tag that already names an animal is left alone', () {
        final rows = [
          sampleTag(id: 'tag-1').toColumns()..['individual_id'] = 'ind-9',
        ];
        final backup = makeBackup({Tables.tags: rows}, schemaVersion: 15);
        expect(SchemaMigrator.backfillIndividuals(backup.tables), 0);
        expect(backup.rowsFor(Tables.tags).single['individual_id'], 'ind-9');
      });
    });

    group('v19 (task 11.323): an estimate with no ellipse says so', () {
      Map<String, Object?> estimate(String id, double major, double minor) =>
          sampleEstimatedPosition(id: id).toColumns()
            ..['semi_major_axis'] = major
            ..['semi_minor_axis'] = minor
            ..['rotation_angle'] = 12.5;

      test("a v18 archive's 0 × 0 ellipse becomes none, and a real one is "
          'kept to the digit', () {
        final backup = makeBackup({
          Tables.estimatedPositions: [
            estimate('two-bearings', 0, 0),
            estimate('real', 220.5, 90.25),
          ],
        }, schemaVersion: 18);
        SchemaMigrator.migrateToCurrent(backup);
        final rows = {
          for (final r in backup.rowsFor(Tables.estimatedPositions))
            r['position_id']: r,
        };
        final none = rows['two-bearings']!;
        expect(none['semi_major_axis'], isNull);
        expect(none['semi_minor_axis'], isNull);
        expect(none['rotation_angle'], isNull);
        expect(
          RowValidator.validate(Tables.estimatedPositions, none),
          isEmpty,
          reason: 'the imported row is one the sync rules accept',
        );
        final real = rows['real']!;
        expect(real['semi_major_axis'], 220.5);
        expect(real['semi_minor_axis'], 90.25);
        expect(real['rotation_angle'], 12.5);
      });

      test('migrating the same payload twice changes nothing more', () {
        final backup = makeBackup({
          Tables.estimatedPositions: [estimate('real', 220.5, 90.25)],
        }, schemaVersion: 18);
        SchemaMigrator.migrateToCurrent(backup);
        final once = {...backup.rowsFor(Tables.estimatedPositions).single};
        SchemaMigrator.emptyZeroEllipses(backup.tables);
        expect(backup.rowsFor(Tables.estimatedPositions).single, once);
      });
    });

    group('v17 (task 11.243): a tag is equipment, and four columns leave it',
        () {
      /// A v16 tag row, built by hand because no model in this build can
      /// produce one any more.
      Map<String, Object?> v16Tag(String id) =>
          sampleTag(id: id).toColumns()
            ..['date_put_on'] = '2026-01-01T00:00:00Z'
            ..['date_removed'] = '2026-06-01T00:00:00Z'
            ..['capture_date'] = '2026-01-01T00:00:00Z'
            ..['individual_id'] = 'marie';

      test('the four columns are stripped and nothing replaces them', () {
        // **Lossy on purpose** (design §9, and `_lowestMigratableMajor`'s
        // amended contract). The device's own v17 migration drops the same
        // four columns and creates no deployments; this mirrors it, so an
        // archive imported after the wipe lands in exactly the state it
        // would have been in had it been on the device through the
        // migration.
        final backup = makeBackup(
          {Tables.tags: [v16Tag('tag-1')]},
          schemaVersion: 16,
        );
        SchemaMigrator.migrateToCurrent(backup);
        final tag = backup.rowsFor(Tables.tags).single;
        for (final column in [
          'date_put_on',
          'date_removed',
          'capture_date',
          'individual_id',
        ]) {
          expect(tag.containsKey(column), isFalse, reason: column);
        }
        expect(
          backup.rowsFor(Tables.deployments),
          isEmpty,
          reason:
              'no deployment is synthesised — one built here would exist on '
              'the importing device and not on the device that wrote the '
              'archive, whose own migration deleted it, and two devices '
              "disagreeing about a project's history is worse than both "
              'forgetting it',
        );
      });

      test('every other column survives — this drops four, not the row', () {
        final before = v16Tag('tag-1');
        final backup = makeBackup(
          {Tables.tags: [{...before}]},
          schemaVersion: 16,
        );
        SchemaMigrator.migrateToCurrent(backup);
        final after = backup.rowsFor(Tables.tags).single;
        for (final entry in before.entries) {
          if (const {
            'date_put_on',
            'date_removed',
            'capture_date',
            'individual_id',
          }.contains(entry.key)) {
            continue;
          }
          expect(after[entry.key], entry.value, reason: entry.key);
        }
      });

      test('idempotent: a row with none of them is untouched', () {
        final rows = [sampleTag(id: 'tag-1').toColumns()];
        final backup = makeBackup({Tables.tags: rows}, schemaVersion: 16);
        expect(
          SchemaMigrator.dropDeploymentColumnsFromTags(backup.tables),
          0,
        );
      });

      test('migrating the same payload twice creates one animal, not two',
          () {
        // **The defect this catches was live and cost a whole import.** The
        // v16 step decided whether it had already run by reading
        // `Tags.individual_id` — which v17 then deletes, three versions
        // later. A payload migrated twice (the merger migrates what a caller
        // may already have migrated, which is exactly what
        // `forked_collar_archive_test` does) therefore ran v16 again, saw no
        // link, and minted a second `Individuals` row under the same key;
        // the merge died on a UNIQUE violation and took the import with it.
        //
        // Found by that test going red, not by anybody predicting it.
        final backup = makeBackup(
          {Tables.tags: [sampleTag(id: 'tag-1').toColumns()]},
          schemaVersion: 15,
        );
        SchemaMigrator.migrateToCurrent(backup);
        SchemaMigrator.migrateToCurrent(backup);
        expect(backup.rowsFor(Tables.individuals), hasLength(1));
        expect(
          backup.rowsFor(Tables.individuals).single['individual_id'],
          'tag-1',
        );
      });
    });
  });
}

/// **v15 (task 11.225's repair, carried into the archive reader by task
/// 10.87).** A v14 archive written by a device that forked a shared collar
/// carries "no signal" entries naming the *original* tag id — a row the
/// archive's project no longer holds — beside the project's own copy, whose
/// `lineage_id` is that original id. The step re-points the entry to the
/// copy, scoped to the row's own project, exactly as the device migration
/// does.
void v15RelinkTests() {
  const project = 'project-1';
  const original = 'tag-shared';
  const copy = 'tag-copy';

  Map<String, Object?> copyTag() =>
      sampleTag(id: copy, projectId: project, lineageId: original).toColumns();

  Map<String, Object?> noSignal({List<String> ids = const [original]}) =>
      sampleNonDetection(id: 'nd-1', projectId: project).toColumns()
        ..['tag_ids_listened_for'] = DbCodec.encodeStringList(ids);

  List<String> idsOf(ProjectBackup b) => DbCodec.decodeStringList(
        b.rowsFor(Tables.nonDetections).single['tag_ids_listened_for'],
      );

  group('SchemaMigrator v15 — dangling no-signal ids in a v14 archive', () {
    test('an id naming no tag in the payload is re-pointed to the project\'s '
        'same-lineage copy', () {
      final backup = makeBackup(
        {Tables.tags: [copyTag()], Tables.nonDetections: [noSignal()]},
        schemaVersion: 14,
        projectId: project,
      );
      expect(SchemaMigrator.migrateToCurrent(backup), 14);
      expect(idsOf(backup), [copy]);
    });

    test('an id that resolves in the payload is left alone, and one with no '
        'same-lineage copy is left alone too', () {
      final backup = makeBackup(
        {
          Tables.tags: [
            copyTag(),
            sampleTag(id: 'tag-own', projectId: project).toColumns(),
          ],
          Tables.nonDetections: [
            noSignal(ids: ['tag-own', original, 'tag-unknown']),
          ],
        },
        schemaVersion: 14,
        projectId: project,
      );
      SchemaMigrator.migrateToCurrent(backup);
      expect(idsOf(backup), ['tag-own', copy, 'tag-unknown']);
    });

    test('scoped to the row\'s own project: a same-lineage tag in another '
        'project is not a replacement', () {
      final backup = makeBackup(
        {
          Tables.tags: [
            sampleTag(id: copy, projectId: 'project-2', lineageId: original)
                .toColumns(),
          ],
          Tables.nonDetections: [noSignal()],
        },
        schemaVersion: 14,
        projectId: project,
      );
      SchemaMigrator.migrateToCurrent(backup);
      expect(idsOf(backup), [original], reason: 'left dangling rather than '
          'cross-linked — §5.9(b)\'s scoping');
    });

    test('a v15 archive is not touched, and running the step twice rewrites '
        'nothing the second time', () {
      final tables = {
        Tables.tags: [copyTag()],
        Tables.nonDetections: [noSignal()],
      };
      expect(SchemaMigrator.relinkNonDetections(tables), 1);
      expect(SchemaMigrator.relinkNonDetections(tables), 0);
      final current = makeBackup(
        {Tables.tags: [copyTag()], Tables.nonDetections: [noSignal()]},
        schemaVersion: latestSchemaVersion,
        projectId: project,
      );
      SchemaMigrator.migrateToCurrent(current);
      expect(idsOf(current), [original],
          reason: 'a current archive is the exporter\'s answer, not ours');
    });

    test('the sealed-column obligation still holds with this reader in the '
        'tree', () {
      expect(assertSealedColumnsFeedNoReachability, returnsNormally);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/quick_add.dart';
import 'package:tritrack/data/repositories/tag_library_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.321, item 3 — quick add: many animals and collars at once.**
///
/// The project holds Marie, wearing 150.321 since March 1st, and 150.523 on
/// the shelf. The Tag Library holds Rex (150.900) and two collars that both
/// read 151.200 — the case Michael said must be asked about, never guessed.
void main() {
  late AppDatabase database;
  const projectId = 'project-1';
  final day = DateTime(2026, 3, 10);
  final defaults = QuickAddDefaults(attachedDate: day, species: 'Coyote');

  setUp(() async {
    database = await AppDatabase.openInMemory();
    final db = database.raw;
    await UserRepository(db).insert(sampleUser());
    await ProjectRepository(db).insert(sampleProject(id: projectId));
    await IndividualRepository(db)
        .insert(sampleIndividual(id: 'marie', name: 'Marie'));
    final tags = TagRepository(db);
    await tags.insert(
      sampleTag(id: 'collar-a', tagName: '150.321', frequencyMhz: 150.321),
      recordInLibrary: false,
    );
    await tags.insert(
      sampleTag(id: 'collar-b', tagName: '150.523', frequencyMhz: 150.523),
      recordInLibrary: false,
    );
    await DeploymentRepository(db).link(
      sampleDeployment(
        id: 'marie-a',
        tagId: 'collar-a',
        individualId: 'marie',
        attachedDate: DateTime(2026, 3, 1),
      ),
    );
    final library = TagLibraryRepository(db);
    for (final (id, name, mhz) in [
      ('lib-rex', 'Rex', 150.900),
      ('lib-x1', 'Twin one', 151.200),
      ('lib-x2', 'Twin two', 151.2001),
    ]) {
      await library.insert(
        sampleTagLibraryEntry(
          id: id,
          lineageId: 'l-$id',
          tagName: name,
          frequencyMhz: mhz,
        ),
      );
    }
  });

  tearDown(() => database.close());

  Future<QuickAddPreview> plan(
    List<QuickAddRow> rows, {
    Map<int, String> choices = const {},
  }) async {
    final db = database.raw;
    return QuickAddPlanner.plan(
      rows: rows,
      defaults: defaults,
      projectId: projectId,
      projectTags: await TagRepository(db).findByProject(projectId),
      library: await TagLibraryRepository(db).findAll(),
      animals: await IndividualRepository(db).findByProject(projectId),
      deployments: await DeploymentRepository(db).findByProject(projectId),
      choices: choices,
    );
  }

  Future<int> commit(QuickAddPreview preview, {String user = 'user-1'}) =>
      QuickAddCommit.commit(
        database.raw,
        preview,
        projectId: projectId,
        defaults: defaults,
        modifiedBy: user,
      );

  group('reading a paste or a CSV', () {
    test('a spreadsheet paste with a header, in any column order', () {
      final rows = QuickAddPaste.parse(
        'Frequency\tAnimal\tSpecies\n150.111\tAda\t\n150.222\tBea\tFox\n',
      );
      expect([for (final r in rows) r.name], ['Ada', 'Bea']);
      expect([for (final r in rows) r.frequency], ['150.111', '150.222']);
      expect(rows[0].species, isNull);
      expect(rows[1].species, 'Fox');
    });

    test('no header: name then frequency, either way round', () {
      final rows = QuickAddPaste.parse('Ada,150.111\n150.222,Bea\r\n\n');
      expect([for (final r in rows) (r.name, r.frequency)], [
        ('Ada', '150.111'),
        ('Bea', '150.222'),
      ]);
    });
  });

  group('the preview', () {
    test('each frequency is matched: a project tag reused, a library tag '
        'copied in, otherwise a new tag', () async {
      final preview = await plan(const [
        QuickAddRow(name: 'Ada', frequency: '150.523'),
        QuickAddRow(name: 'Bea', frequency: '150.900'),
        QuickAddRow(name: 'Cy', frequency: '150.777'),
      ]);
      expect([for (final r in preview.rows) r.source], [
        QuickAddSource.projectTag,
        QuickAddSource.library,
        QuickAddSource.newTag,
      ]);
      expect(preview.summary,
          '3 animals, 1 new tag, 1 from your library, 1 already on this project');
      expect(preview.canSave, isTrue);
    });

    test('WATCHED RED: a frequency that matches two library tags is asked '
        'about, never guessed', () async {
      final preview = await plan(const [
        QuickAddRow(name: 'Ada', frequency: '151.200'),
      ]);
      final row = preview.rows.single;
      expect(row.source, isNull, reason: 'nothing picked for the person');
      expect(row.needsChoice, isTrue);
      expect([for (final c in row.candidates) c.key], [
        'library:lib-x1',
        'library:lib-x2',
        'new',
      ], reason: 'both tags, and a new one, are offered');
      expect(preview.canSave, isFalse);
      expect(preview.summary, '1 animal, 1 tag to choose');

      final chosen = await plan(
        const [QuickAddRow(name: 'Ada', frequency: '151.200')],
        choices: {1: 'library:lib-x2'},
      );
      expect(chosen.rows.single.libraryEntry!.tagId, 'lib-x2');
      expect(chosen.canSave, isTrue);
    });

    test('WATCHED RED: a row the deployment rules refuse is a problem, and '
        'nothing can be saved', () async {
      final preview = await plan(const [
        QuickAddRow(name: 'Ada', frequency: '150.321'),
        QuickAddRow(name: 'Bea', frequency: '150.777'),
      ]);
      expect(preview.rows.first.problem, 'This tag is on Marie on that date.');
      expect(preview.summary, '2 animals, 1 new tag, 1 problem');
      expect(preview.canSave, isFalse);
    });

    test('a duplicate in the table, a name already on the project, and an '
        'unreadable frequency are each a problem on their own row', () async {
      final preview = await plan(const [
        QuickAddRow(name: 'Ada', frequency: '150.777'),
        QuickAddRow(name: 'Bea', frequency: '150.7770'),
        QuickAddRow(name: 'ada', frequency: '150.888'),
        QuickAddRow(name: 'marie', frequency: '150.999'),
        QuickAddRow(name: 'Cy', frequency: '15O.1'),
        QuickAddRow(),
        QuickAddRow(frequency: '150.444'),
      ]);
      expect([for (final r in preview.rows) (r.number, r.problem)], [
        (1, null),
        (2, 'Same frequency as row 1.'),
        (3, 'Same name as row 1.'),
        (4, 'Already an animal on this project.'),
        (5, 'Frequency is not a number.'),
        (7, 'Needs a name.'),
      ], reason: 'a blank row is skipped, and numbers match the table');
    });

    test('a new tag gets the rates from "Same for all", and its ID is the '
        'frequency unless the row names one', () {
      final tag = QuickAddPlanner.newTagFor(
        const QuickAddRow(name: 'Ada', frequency: '150.777'),
        150.777,
        QuickAddDefaults(
          attachedDate: day,
          normalRateBpm: 40,
          mortalityRateBpm: 80,
        ),
        projectId: projectId,
        tagId: 't',
        sync: sampleSync(),
      );
      expect(tag.tagName, '150.777');
      expect(tag.pulseRate, 40);
      expect(tag.pulseMode2RateBpm, 80);
    });

    test('WATCHED RED (task 11.339, replacing 11.324\'s default): a row '
        'whose Tag ID this project already has, on another frequency, stops '
        'and asks — nothing is saved until the person chooses', () async {
      const row = QuickAddRow(name: 'Kea', frequency: '152.000', tagName: '150.523 ');
      final asked = await plan([row]);
      final open = asked.rows.single;
      expect(open.needsChoice, isTrue,
          reason: 'Michael, 2026-10-08: a pasted table with a coincidental '
              'Tag ID and a correct new frequency must not quietly attach the '
              'animal to the existing collar — it stops and asks');
      expect(open.problem, isNull);
      expect(open.source, isNull);
      expect(open.sameTagId, isTrue,
          reason: 'the review line says why it is asking: the Tag ID matched');
      expect(open.projectTag?.tagId, 'collar-b',
          reason: 'the review line names the existing tag and its frequency');
      expect(open.candidates.map((c) => c.key), ['project:collar-b', 'new'],
          reason: 'Use the existing tag, or Create anyway — in that order');
      expect(asked.canSave, isFalse, reason: 'Add all waits for the choice');
      expect(asked.unchosen, 1);

      final chosenExisting =
          (await plan([row], choices: {1: 'project:collar-b'})).rows.single;
      expect(chosenExisting.source, QuickAddSource.projectTag);
      expect(chosenExisting.projectTag!.tagId, 'collar-b');
      expect(chosenExisting.sameTagId, isTrue);

      final chosenNew = (await plan([row], choices: {1: 'new'})).rows.single;
      expect(chosenNew.source, QuickAddSource.newTag);
      expect(chosenNew.sameTagId, isTrue);

      // Saving the existing-tag choice writes no second tag.
      expect(
        await commit(await plan([row], choices: {1: 'project:collar-b'})),
        1,
      );
      final tags = await TagRepository(database.raw).findByProject(projectId);
      expect(tags.where((t) => t.tagName == '150.523'), hasLength(1));
    });

    test('a row whose Tag ID and frequency both match a tag on this project '
        'still uses that tag without asking', () async {
      const row = QuickAddRow(name: 'Kea', frequency: '150.523', tagName: '150.523');
      final planned = (await plan([row])).rows.single;
      expect(planned.needsChoice, isFalse);
      expect(planned.source, QuickAddSource.projectTag);
      expect(planned.projectTag!.tagId, 'collar-b');
    });

    test('a Tag ID on a tag that is busy on that date asks first, and choosing '
        'the existing tag is then a problem the person can still answer with '
        'a second tag', () async {
      const row = QuickAddRow(name: 'Kea', frequency: '152.000', tagName: '150.321');
      final open = (await plan([row])).rows.single;
      expect(open.needsChoice, isTrue);
      expect(open.candidates.map((c) => c.key), ['project:collar-a', 'new']);
      final busy =
          (await plan([row], choices: {1: 'project:collar-a'})).rows.single;
      expect(busy.problem, 'This tag is on Marie on that date.');
      expect(busy.sameTagId, isTrue);
      expect(busy.candidates.map((c) => c.key), ['project:collar-a', 'new']);
      final chosenNew = (await plan([row], choices: {1: 'new'})).rows.single;
      expect(chosenNew.problem, isNull);
      expect(chosenNew.source, QuickAddSource.newTag);
    });
  });

  group('saving', () {
    test('every row is written: the animal, its tag, and the link from the '
        'day the tags went on', () async {
      final preview = await plan(const [
        QuickAddRow(name: 'Ada', frequency: '150.523'),
        QuickAddRow(name: 'Bea', frequency: '150.900', species: 'Fox'),
        QuickAddRow(name: 'Cy', frequency: '150.777'),
      ]);
      expect(await commit(preview), 3);

      final db = database.raw;
      final animals = {
        for (final a in await IndividualRepository(db).findByProject(projectId))
          a.name: a,
      };
      expect(animals.keys, containsAll(['Ada', 'Bea', 'Cy']));
      expect(animals['Ada']!.species, 'Coyote', reason: 'Same for all');
      expect(animals['Bea']!.species, 'Fox', reason: 'the row overrides it');
      expect(animals['Ada']!.status, IndividualStatus.unknown);

      final tags = await TagRepository(db).findByProject(projectId);
      expect(tags.singleWhere((t) => t.tagName == 'Rex').lineageId, 'l-lib-rex',
          reason: 'copied in, keeping its lineage');
      expect(tags.where((t) => t.frequencyMhz == 150.777), hasLength(1));

      final links = await DeploymentRepository(db).findByProject(projectId);
      final added = links.where((d) => d.deploymentId != 'marie-a').toList();
      expect(added, hasLength(3));
      expect(added.every((d) => d.attachedDate!.isAtSameMomentAs(day)), isTrue,
          reason: 'every link starts on the day the tags went on');
      expect(
        added.singleWhere((d) => d.individualId == animals['Ada']!.individualId)
            .tagId,
        'collar-b',
        reason: 'the project\'s own tag is reused, not copied',
      );
    });

    test('WATCHED RED: a save that fails partway writes nothing', () async {
      // The preview is fine when it is made. Then, before Save, another
      // write puts row 2's tag on Marie's neighbour — the kind of change a
      // sync can deliver. Row 1 would write; row 2's link is refused. All
      // of it must roll back.
      final preview = await plan(const [
        QuickAddRow(name: 'Ada', frequency: '150.777'),
        QuickAddRow(name: 'Bea', frequency: '150.523'),
      ]);
      expect(preview.canSave, isTrue);
      final db = database.raw;
      await IndividualRepository(db)
          .insert(sampleIndividual(id: 'kea', name: 'Kea'));
      await DeploymentRepository(db).link(
        sampleDeployment(
          id: 'kea-b',
          tagId: 'collar-b',
          individualId: 'kea',
          attachedDate: DateTime(2026, 3, 2),
        ),
      );

      await expectLater(commit(preview), throwsA(isA<OverlappingDeployment>()));
      final names = [
        for (final a in await IndividualRepository(db).findByProject(projectId))
          a.name,
      ];
      expect(names, isNot(contains('Ada')),
          reason: 'row 1 rolled back with row 2');
      expect(
        (await TagRepository(db).findByProject(projectId))
            .where((t) => t.frequencyMhz == 150.777),
        isEmpty,
      );
      expect(await DeploymentRepository(db).findByProject(projectId),
          hasLength(2), reason: "Marie's and Kea's, and nothing new");
    });

    test('a viewer is refused, and nothing is written', () async {
      final db = database.raw;
      await UserRepository(db).insert(sampleUser(id: 'user-2', email: 'v@x.com'));
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(id: 'm-2', userId: 'user-2', role: ProjectRole.viewer)
            .toColumns(),
      );
      final preview = await plan(const [
        QuickAddRow(name: 'Ada', frequency: '150.777'),
      ]);
      await expectLater(
        commit(preview, user: 'user-2'),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(
        (await IndividualRepository(db).findByProject(projectId))
            .map((a) => a.name),
        ['Marie'],
      );
    });

    test('a preview with a problem cannot be saved at all', () async {
      final preview = await plan(const [
        QuickAddRow(name: 'Ada', frequency: '150.321'),
      ]);
      await expectLater(commit(preview), throwsA(isA<StateError>()));
    });
  });
}

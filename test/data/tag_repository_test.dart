import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_library_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/tag_version_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';

import 'fixtures.dart';

/// **The colour round-robin is per project since task 11.219 (§2.7), and
/// counts animals since task 11.240.**
///
/// It used to count every tag row on the device. Copy-on-add doubles the
/// device-wide row count every time a collar is put into a second project
/// without adding a single tag to either project's map, so a device-global
/// counter would drift twice as fast and make the *within-project*
/// collisions the legend actually cares about more likely, not less. Colour
/// is the map legend's key (Phase 4.4), and a legend is per project.
///
/// The round-robin lives on `IndividualRepository` now — colour is the
/// animal's — but `TagRepository.insert` creates one animal per new tag, so
/// the tests below still count through tag creation, which is the path every
/// screen takes.
void main() {
  late AppDatabase database;
  late TagRepository tags;
  late IndividualRepository individuals;

  const projectA = 'project-1';
  const projectB = 'project-2';

  setUp(() async {
    database = await AppDatabase.openInMemory();
    tags = TagRepository(database.raw);
    individuals = IndividualRepository(database.raw);
    await UserRepository(database.raw).insert(sampleUser());
    final projects = ProjectRepository(database.raw);
    await projects.insert(sampleProject(id: projectA));
    await projects.insert(sampleProject(id: projectB));
  });

  tearDown(() async {
    await database.close();
  });

  test('nextColorHex round-robins as animals are named, not as collars are '
      'created', () async {
    // **The title changed with the behaviour** (task 11.243). It said "as
    // tags are created", and that was true while `TagRepository.insert` made
    // an animal per collar. A tag is equipment now and makes none, so
    // entering a shelf of transmitters spends no palette colours at all —
    // which is right: colour is the map legend's key, and an unlinked collar
    // draws nothing on the map that needs distinguishing.
    expect(
      await individuals.nextColorHex(projectId: projectA),
      TagColorPalette.colors[0],
    );

    await tags.insert(sampleTag(id: 'tag-1', projectId: projectA));
    expect(
      await individuals.nextColorHex(projectId: projectA),
      TagColorPalette.colors[0],
      reason: 'a collar on nobody costs the palette nothing',
    );

    await individuals.insert(
      sampleIndividual(
        id: 'animal-1',
        projectId: projectA,
        colorHex: await individuals.nextColorHex(projectId: projectA),
      ),
    );
    expect(
      await individuals.nextColorHex(projectId: projectA),
      TagColorPalette.colors[1],
    );

    await individuals.insert(
      sampleIndividual(
        id: 'animal-2',
        projectId: projectA,
        colorHex: await individuals.nextColorHex(projectId: projectA),
      ),
    );
    expect(
      await individuals.nextColorHex(projectId: projectA),
      TagColorPalette.colors[2],
    );
  });

  test('nextColorHex wraps around after the palette is exhausted', () async {
    for (var i = 0; i < TagColorPalette.colors.length; i++) {
      // **Animals, not collars** (task 11.240's change, sharpened by
      // 11.243): creating a tag creates no animal at all now, so the
      // round-robin only moves when a person names one.
      await individuals.insert(
        sampleIndividual(
          id: 'animal-$i',
          projectId: projectA,
          colorHex: await individuals.nextColorHex(projectId: projectA),
        ),
      );
    }
    expect(
      await individuals.nextColorHex(projectId: projectA),
      TagColorPalette.colors[0],
    );
  });

  test('a second project starts the palette again, and that is the point',
      () async {
    // The §2.7 change, asserted rather than described. Two projects each
    // holding one collar both get palette colour 0 — before task 11.219 the
    // second would have been colour 1, spending the palette twice as fast
    // for a collision that cannot happen: the two are never on one legend.
    await individuals.insert(
      sampleIndividual(
        id: 'animal-a',
        projectId: projectA,
        colorHex: await individuals.nextColorHex(projectId: projectA),
      ),
    );
    expect(
      await individuals.nextColorHex(projectId: projectB),
      TagColorPalette.colors[0],
    );
  });

  test('individualCount counts this project\'s animals and nobody else\'s',
      () async {
    // **Creating a collar no longer creates an animal** (task 11.243): this
    // test counted tags at v16 because `insert` made one per collar. It
    // counts animals somebody actually entered now.
    expect(await individuals.individualCount(projectId: projectA), 0);

    await tags.insert(sampleTag(id: 'tag-1', projectId: projectA));
    expect(
      await individuals.individualCount(projectId: projectA),
      0,
      reason: 'a collar is equipment — it says nothing about an animal',
    );

    await individuals.insert(sampleIndividual(id: 'a1', projectId: projectA));
    await individuals.insert(sampleIndividual(id: 'a2', projectId: projectA));
    expect(await individuals.individualCount(projectId: projectA), 2);

    await individuals.insert(sampleIndividual(id: 'b1', projectId: projectB));
    expect(await individuals.individualCount(projectId: projectA), 2);
    expect(await individuals.individualCount(projectId: projectB), 1);
  });

  test('a second collar on the same animal does not spend a palette colour',
      () async {
    // Task 11.240's reason for counting animals rather than collars: Marie
    // on her second transmitter is still one colour on the legend. The
    // second collar is a second *deployment* now (task 11.243), and a
    // deployment is not an animal, so the count is unmoved.
    await individuals.insert(
      sampleIndividual(id: 'marie', projectId: projectA),
    );
    await tags.insert(sampleTag(id: 'tag-1', projectId: projectA));
    await tags.insert(sampleTag(id: 'tag-2', projectId: projectA));
    final deployments = DeploymentRepository(database.raw);
    // **The boundary is one bare day apart, not the same one** — a same-day
    // bare-day handover is a genuine overlap under the no-tolerance rule
    // (task 11.263). Built through `deploymentDateFor` rather than a second
    // hand-written literal, so each end is a real bare day in whatever zone
    // reads it (task 11.276).
    await deployments.link(
      sampleDeployment(
        id: 'd1',
        projectId: projectA,
        tagId: 'tag-1',
        individualId: 'marie',
        attachedDate: deploymentDateFor(DateTime.utc(2025)),
        removedDate: deploymentDateFor(DateTime.utc(2025, 12, 31)),
      ),
    );
    await deployments.link(
      sampleDeployment(
        id: 'd2',
        projectId: projectA,
        tagId: 'tag-2',
        individualId: 'marie',
        attachedDate: deploymentDateFor(DateTime.utc(2026)),
      ),
    );
    expect(await individuals.individualCount(projectId: projectA), 1);
    expect(
      await individuals.nextColorHex(projectId: projectA),
      TagColorPalette.colors[1],
    );
  });

  group('copy-on-add', () {
    test('a copy is a new row with the same lineage, in the other project',
        () async {
      final library = TagLibraryRepository(database.raw);
      final entry = sampleTagLibraryEntry(id: 'lib-1', lineageId: 'lineage-1');
      await library.insert(entry);

      final copy = await tags.copyFromLibrary(
        entry,
        projectId: projectA,
        modifiedBy: 'user-1',
      );

      expect(copy.projectId, projectA);
      expect(copy.lineageId, 'lineage-1');
      expect(
        copy.tagId,
        isNot(entry.tagId),
        reason: 'a copy takes a fresh identity — that is what makes editing '
            'one project\'s tag leave the library and every other project '
            'alone',
      );
      expect(
        copy.copiedAt,
        isNotNull,
        reason: 'this copy genuinely was made now, which is the one case '
            'copied_at is not null',
      );
      expect(
        copy.colorHex,
        entry.colorHex,
        reason: '§2.7: one collar looks the same in every project a person '
            'holds',
      );
    });

    test('copying a collar into a project creates no animal for it '
        '(task 11.243)', () async {
      // **The library colour was a seed for the animal the copy created**
      // (task 11.241's decision). The copy creates no animal now — a collar
      // in a project is a collar that project owns, not a collar that is on
      // something — so the seed has nowhere to land and the copy draws the
      // neutral colour until somebody links it.
      //
      // `TagLibraryEntry.colorHex` is therefore read by nothing at all
      // today. Whether the linking screen should offer it as a new animal's
      // starting colour is task 11.244's call, which is why the column
      // stays.
      final library = TagLibraryRepository(database.raw);
      final entry = sampleTagLibraryEntry(
        id: 'lib-1',
        lineageId: 'lineage-1',
      ).copyWith(colorHex: '#0072B2');
      await library.insert(entry);

      final copy = await tags.copyFromLibrary(
        entry,
        projectId: projectA,
        modifiedBy: 'user-1',
      );
      expect(
        await IndividualRepository(
          database.raw,
        ).findByProject(projectA),
        isEmpty,
      );
      expect(
        (await tags.findById(copy.tagId, projectId: projectA))!.colorHex,
        TagColorPalette.noIndividual,
      );
    });

    test('two projects can hold the same collar, and editing one leaves the '
        'other alone', () async {
      final library = TagLibraryRepository(database.raw);
      final entry = sampleTagLibraryEntry(id: 'lib-1', lineageId: 'lineage-1');
      await library.insert(entry);

      final inA = await tags.copyFromLibrary(
        entry,
        projectId: projectA,
        modifiedBy: 'user-1',
      );
      final inB = await tags.copyFromLibrary(
        entry,
        projectId: projectB,
        modifiedBy: 'user-1',
      );
      expect(inA.lineageId, inB.lineageId);
      expect(inA.tagId, isNot(inB.tagId));

      await tags.update(
        inA.copyWith(tagName: 'Renamed in A'),
        actor: const MutationActor.replication('test'),
        intent: TagEditIntent.correction,
      );

      final reloadedB = await tags.findById(inB.tagId, projectId: projectB);
      expect(reloadedB!.tagName, entry.tagName);
      expect(
        (await tags.findById(inA.tagId, projectId: projectA))!.tagName,
        'Renamed in A',
      );
      expect(
        (await library.findById(entry.tagId))!.tagName,
        entry.tagName,
        reason: 'the library entry is not touched by either project',
      );
    });

    test('creating a tag in a project records the collar in the library too',
        () async {
      // Otherwise "copy from your library" is an option nobody who never
      // used the library could ever take.
      await tags.insert(
        sampleTag(id: 'tag-1', projectId: projectA, lineageId: 'lineage-1'),
      );
      final library = TagLibraryRepository(database.raw);
      final entries = await library.findAll();
      expect(entries, hasLength(1));
      expect(entries.single.lineageId, 'lineage-1');
      expect(
        entries.single.tagId,
        isNot('tag-1'),
        reason: 'the library entry is its own row, not the project\'s',
      );
    });

    test('a collar the library already knows about is not recorded twice',
        () async {
      await tags.insert(
        sampleTag(id: 'tag-a', projectId: projectA, lineageId: 'lineage-1'),
      );
      await tags.insert(
        sampleTag(id: 'tag-b', projectId: projectB, lineageId: 'lineage-1'),
      );
      expect(await TagLibraryRepository(database.raw).findAll(), hasLength(1));
    });

    test('a tag created for somebody else\'s bearing is not claimed as yours',
        () async {
      // The paste screen's case: a shared bearing describes a colleague's
      // transmitter, and recording it as one of *your* collars would claim
      // their equipment.
      await tags.insert(
        sampleTag(id: 'tag-1', projectId: projectA),
        recordInLibrary: false,
      );
      expect(await TagLibraryRepository(database.raw).findAll(), isEmpty);
    });
  });

  /// **Task 11.250.** A library edit reaches no project by construction, so
  /// this is the one route that fixes a typo everywhere: apply the library's
  /// current values to every project's copy of the same collar, in one push.
  group('pushToProjects (task 11.250)', () {
    test('applies the library\'s new values to every copy, keeping each '
        'project\'s own version chain', () async {
      final library = TagLibraryRepository(database.raw);
      final entry = sampleTagLibraryEntry(id: 'lib-1', lineageId: 'lineage-1');
      await library.insert(entry);
      final inA = await tags.copyFromLibrary(
        entry,
        projectId: projectA,
        modifiedBy: 'user-1',
      );
      final inB = await tags.copyFromLibrary(
        entry,
        projectId: projectB,
        modifiedBy: 'user-1',
      );

      final corrected = entry.copyWith(tagName: 'Fixed');
      final result = await tags.pushToProjects(
        corrected,
        intent: TagEditIntent.correction,
        actor: const MutationActor.replication('test'),
      );

      expect(result, (updated: 2, refused: 0));
      expect(
        (await tags.findById(inA.tagId, projectId: projectA))!.tagName,
        'Fixed',
      );
      expect(
        (await tags.findById(inB.tagId, projectId: projectB))!.tagName,
        'Fixed',
      );

      final versions = TagVersionRepository(database.raw);
      final versionA = await versions.currentFor(inA.tagId);
      final versionB = await versions.currentFor(inB.tagId);
      expect(versionA!.tagId, inA.tagId);
      expect(versionB!.tagId, inB.tagId);
      expect(
        versionA.tagVersionId,
        isNot(versionB.tagVersionId),
        reason: 'copy-on-add applied to history — each project keeps its '
            'own chain, never collapsed into one',
      );
    });

    test('colour is never pushed, even when the library\'s differs', () async {
      final library = TagLibraryRepository(database.raw);
      final entry = sampleTagLibraryEntry(
        id: 'lib-1',
        lineageId: 'lineage-1',
      ).copyWith(colorHex: '#0072B2');
      await library.insert(entry);
      final copy = await tags.copyFromLibrary(
        entry,
        projectId: projectA,
        modifiedBy: 'user-1',
      );
      final before = await tags.findById(copy.tagId, projectId: projectA);

      await tags.pushToProjects(
        entry.copyWith(colorHex: '#D55E00', notes: 'new note'),
        intent: null,
        actor: const MutationActor.replication('test'),
      );

      final after = await tags.findById(copy.tagId, projectId: projectA);
      expect(
        after!.colorHex,
        before!.colorHex,
        reason: 'Tags.color_hex is retired and read by nothing; pushing the '
            'library\'s would risk moving the individual\'s colour',
      );
      expect(after.notes, 'new note');
    });

    test('a project the actor may not write to is refused and counted, not '
        'skipped in silence', () async {
      // projectA: user-1 owns it (the setUp default). projectB here belongs
      // to somebody else, with user-1 only a contributor on it — the
      // creator-fallback rule that makes the owner_user_id the owner absent
      // any membership row means the project must genuinely belong to
      // another user, not just lack a membership row of user-1's own.
      const otherOwner = 'user-2';
      await UserRepository(
        database.raw,
      ).insert(sampleUser(id: otherOwner, email: 'other@example.com'));
      const projectC = 'project-owned-by-someone-else';
      await ProjectRepository(
        database.raw,
      ).insert(sampleProject(id: projectC, ownerUserId: otherOwner));
      await database.raw.insert(
        Tables.projectMemberships,
        sampleMembership(
          id: 'm-contributor-c',
          projectId: projectC,
          userId: 'user-1',
          role: ProjectRole.contributor,
        ).toColumns(),
      );

      final library = TagLibraryRepository(database.raw);
      final entry = sampleTagLibraryEntry(id: 'lib-1', lineageId: 'lineage-1');
      await library.insert(entry);
      final inA = await tags.copyFromLibrary(
        entry,
        projectId: projectA,
        modifiedBy: 'user-1',
      );
      final inC = await tags.copyFromLibrary(
        entry,
        projectId: projectC,
        modifiedBy: 'user-1',
      );

      final actor = MutationActor.user('user-1');
      final result = await tags.pushToProjects(
        entry.copyWith(tagName: 'Fixed'),
        intent: TagEditIntent.correction,
        actor: actor,
      );

      expect(
        result,
        (updated: 1, refused: 1),
        reason: 'a push that silently updated three of four would be worse '
            'than one that updated none — every row is counted',
      );
      expect(
        (await tags.findById(inA.tagId, projectId: projectA))!.tagName,
        'Fixed',
        reason: 'owner: updated',
      );
      expect(
        (await tags.findById(inC.tagId, projectId: projectC))!.tagName,
        entry.tagName,
        reason: 'contributor: refused, and left untouched — not partially '
            'applied',
      );
    });
  });

  /// **Task 11.234.** `otherProjectCopyCount` and `libraryCopyCount` used to
  /// be one method, `projectCopyCount`, called from two places that mean
  /// different things by "how many projects hold this". Called with a
  /// project's own tag, it always matched that tag's own row and inflated
  /// the count by one — the real row that found this, Steens' `East Rim`,
  /// had never been copied anywhere and read "One of your projects uses
  /// this collar."
  group('projectCopyCount split (task 11.234)', () {
    test('otherProjectCopyCount excludes the tag\'s own project — the '
        'commonest collar there is, one project, no copies', () async {
      final library = TagLibraryRepository(database.raw);
      await tags.insert(sampleTag(id: 'tag-1', projectId: projectA));

      expect(
        await library.otherProjectCopyCount('tag-1', projectA),
        0,
        reason: 'the only row for this lineage is the tag itself, in its '
            'own project — that must not count as a project "using" it',
      );
    });

    test('otherProjectCopyCount counts a genuine copy in a second project',
        () async {
      final library = TagLibraryRepository(database.raw);
      await tags.insert(sampleTag(id: 'tag-1', projectId: projectA));
      await tags.insert(
        sampleTag(
          id: 'tag-2',
          projectId: projectB,
          lineageId: 'tag-1',
          copiedAt: DateTime(2026, 9, 1),
        ),
        recordInLibrary: false,
      );

      expect(await library.otherProjectCopyCount('tag-1', projectA), 1);
      expect(await library.otherProjectCopyCount('tag-1', projectB), 1,
          reason: 'symmetric — from B\'s side, A is the one other project');
    });

    test('libraryCopyCount counts every project for a library entry, with '
        'no self-match to exclude', () async {
      final library = TagLibraryRepository(database.raw);
      final entry = sampleTagLibraryEntry(id: 'lib-1', lineageId: 'lineage-1');
      await library.insert(entry);

      expect(
        await library.libraryCopyCount('lineage-1'),
        0,
        reason: 'a library entry with no copies in any project',
      );

      await tags.insert(
        sampleTag(id: 'tag-a', projectId: projectA, lineageId: 'lineage-1'),
        recordInLibrary: false,
      );
      expect(await library.libraryCopyCount('lineage-1'), 1);

      await tags.insert(
        sampleTag(id: 'tag-b', projectId: projectB, lineageId: 'lineage-1'),
        recordInLibrary: false,
      );
      expect(await library.libraryCopyCount('lineage-1'), 2);
    });

    /// **Task 11.288.** Deleting a project on this device soft-deletes the
    /// `Projects` row and leaves its tags untouched — neither count ever
    /// asked whether the project a copy belongs to still exists here.
    test('libraryCopyCount does not count a copy in a project this device '
        'has deleted', () async {
      final library = TagLibraryRepository(database.raw);
      final entry = sampleTagLibraryEntry(id: 'lib-1', lineageId: 'lineage-1');
      await library.insert(entry);
      await tags.insert(
        sampleTag(id: 'tag-a', projectId: projectA, lineageId: 'lineage-1'),
        recordInLibrary: false,
      );
      expect(await library.libraryCopyCount('lineage-1'), 1);

      await ProjectRepository(database.raw).softDeleteById(
        projectA,
        actor: const MutationActor.user('user-1'),
      );

      expect(
        await library.libraryCopyCount('lineage-1'),
        0,
        reason: 'the copy still sits in Tags — project deletion does not '
            'cascade — but a project this device has deleted is not one an '
            'edit here would reach',
      );
    });

    test('otherProjectCopyCount does not count a copy in a project this '
        'device has deleted', () async {
      final library = TagLibraryRepository(database.raw);
      await tags.insert(sampleTag(id: 'tag-1', projectId: projectA));
      await tags.insert(
        sampleTag(
          id: 'tag-2',
          projectId: projectB,
          lineageId: 'tag-1',
          copiedAt: DateTime(2026, 9, 1),
        ),
        recordInLibrary: false,
      );
      expect(await library.otherProjectCopyCount('tag-1', projectA), 1);

      await ProjectRepository(database.raw).softDeleteById(
        projectB,
        actor: const MutationActor.user('user-1'),
      );

      expect(
        await library.otherProjectCopyCount('tag-1', projectA),
        0,
        reason: 'projectB is this device\'s own deleted project — editing '
            'tag-1 in projectA no longer reaches it',
      );
    });
  });

  group('removing a tag from a project', () {
    test('is a tombstone, so every bearing that names it still resolves',
        () async {
      await tags.insert(sampleTag(id: 'tag-1', projectId: projectA));
      await tags.removeFromProject(
        'tag-1',
        projectId: projectA,
        actor: const MutationActor.replication('test'),
      );

      expect(await tags.findByProject(projectA), isEmpty);
      final removed = await tags.findByProject(projectA, includeDeleted: true);
      expect(removed, hasLength(1));
      expect(removed.single.sync.isDeleted, isTrue);
    });

    test('can be undone', () async {
      await tags.insert(sampleTag(id: 'tag-1', projectId: projectA));
      const actor = MutationActor.replication('test');
      await tags.removeFromProject('tag-1', projectId: projectA, actor: actor);
      await tags.restoreToProject('tag-1', projectId: projectA, actor: actor);
      expect(await tags.findByProject(projectA), hasLength(1));
    });
  });
}

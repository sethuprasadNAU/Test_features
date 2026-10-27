import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/tag_view_refresh.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// **What `refreshTagViews(projectId: null)` has to mean** — task 11.153's
/// correction to task 11.151.
///
/// 11.151 wrote null as *"the write only touched the global tag database (a
/// rename, a recolour, a retirement) and no link changed"*, and invalidated
/// only the global list on that argument. The argument does not hold:
/// `projectActiveTags` hands back whole `Tag` rows, so the name and the colour
/// a project's tag wheel shows change every time the tag does.
///
/// It is not a corner: **the Tag Database screen's edit dialog offers no
/// project when editing an existing tag**, so `_saveTag` passes null on every
/// rename, retune and recolour there.
void main() {
  const projectId = 'project-1';

  setUp(installFakeSharedPreferences);

  Future<(ProviderContainer, Database)> seed() async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
      ],
    );
    final db = (await container.read(appDatabaseProvider.future)).raw;
    await db.insert(Tables.users, sampleUser(id: 'u1').toColumns());
    await db.insert(
      Tables.projects,
      sampleProject(id: projectId, ownerUserId: 'u1').toColumns(),
    );
    // The animal the tag reads its colour through (task 11.240): the
    // recolour test below is about the colour reaching the wheel, and a tag
    // with nobody named draws the neutral grey whatever anybody writes.
    await db.insert(
      Tables.individuals,
      sampleIndividual(id: 'ind-1', projectId: projectId).toColumns(),
    );
    await db.insert(
      Tables.tags,
      sampleTag(id: 'tag-1', projectId: projectId, tagName: 'Coco').toColumns(),
    );
    // Task 11.243: the link is a dated row, and it is on the same refresh
    // list as the tags and the animals for exactly this reason.
    await db.insert(
      Tables.deployments,
      sampleDeployment(
        projectId: projectId,
        tagId: 'tag-1',
        individualId: 'ind-1',
      ).toColumns(),
    );
    return (container, db);
  }

  test('a rename with no project named still reaches the project tag wheel',
      () async {
    final (container, db) = await seed();
    addTearDown(container.dispose);
    container.listen(projectActiveTagsProvider(projectId), (_, _) {});
    expect(
      (await container.read(projectActiveTagsProvider(projectId).future))
          .single
          .tagName,
      'Coco',
    );

    await db.update(
      Tables.tags,
      {'tag_name': 'Bandit'},
      where: 'tag_id = ?',
      whereArgs: ['tag-1'],
    );
    // Null is what the Tag Database screen passes when an existing tag is
    // edited, because that dialog offers no project to name.
    refreshTagViewsIn(container, projectId: null);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(
      (await container.read(projectActiveTagsProvider(projectId).future))
          .single
          .tagName,
      'Bandit',
      reason:
          'The collar was renamed and the Record screen\'s tag wheel still '
          'offers the old name. A bearing recorded now is attributed to the '
          'right animal — the id did not change — but the person recording it '
          'is reading a name that is no longer true, and it stays that way '
          'until the app is restarted.',
    );
  });

  test('a recolour with no project named reaches it too', () async {
    final (container, db) = await seed();
    addTearDown(container.dispose);
    container.listen(projectActiveTagsProvider(projectId), (_, _) {});
    final before = (await container
            .read(projectActiveTagsProvider(projectId).future))
        .single
        .colorHex;

    // Colour lives on the animal since task 11.240; the tag reads it through.
    await db.update(
      Tables.individuals,
      {'color_hex': '#123456'},
      where: 'project_id = ?',
      whereArgs: [projectId],
    );
    refreshTagViewsIn(container, projectId: null);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(
      (await container.read(projectActiveTagsProvider(projectId).future))
          .single
          .colorHex,
      isNot(before),
      reason:
          'Tag colour is the map\'s legend key (Phase 4.4), so a stale one is '
          'a wrong legend rather than a cosmetic lag.',
    );
  });

  test('naming a project still refreshes that project', () async {
    final (container, db) = await seed();
    addTearDown(container.dispose);
    container.listen(projectTagsProvider(projectId), (_, _) {});
    expect(
      await container.read(projectTagsProvider(projectId).future),
      hasLength(1),
    );

    // A hard delete rather than the tombstone the app writes: this test is
    // about the *refresh* reaching the provider, and `projectTagsProvider`
    // deliberately includes tombstoned rows (a removed tag is still one an
    // owner can put back), so a tombstone would not change what it returns.
    //
    // The deployment goes first (task 11.243): it names this tag, and a hard
    // delete of the parent is refused by the foreign key. The app never does
    // either — it tombstones — so this ordering is a property of the
    // shortcut rather than of any real path.
    await db.delete(
      Tables.deployments,
      where: 'tag_id = ? AND project_id = ?',
      whereArgs: ['tag-1', projectId],
    );
    await db.delete(
      Tables.tags,
      where: 'tag_id = ? AND project_id = ?',
      whereArgs: ['tag-1', projectId],
    );
    refreshTagViewsIn(container, projectId: projectId);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(
      await container.read(projectTagsProvider(projectId).future),
      isEmpty,
    );
  });
}

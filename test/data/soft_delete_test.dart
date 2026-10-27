import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/repositories/base_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';

import 'fixtures.dart';

const _actor = MutationActor.user('user-1');

/// `sampleTag`'s whole primary key. Composite since task 11.219 — a tag id
/// identifies a row only within its project.
const _tagKey = {'tag_id': 'tag-1', 'project_id': 'project-1'};

void main() {
  late AppDatabase database;
  late TagRepository tags;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    tags = TagRepository(database.raw);
    // A tag references its project since task 11.219, so the project has to
    // be there first.
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject());
  });

  tearDown(() async {
    await database.close();
  });

  test('default reads exclude tombstoned rows; includeDeleted surfaces them',
      () async {
    await tags.insert(sampleTag());
    expect(await tags.findAll(), hasLength(1));

    await tags.softDeleteByKey(_tagKey, actor: _actor);

    expect(await tags.findById('tag-1', projectId: 'project-1'), isNull);
    expect(await tags.findAll(), isEmpty);

    final withDeleted = await tags.findById('tag-1', projectId: 'project-1', includeDeleted: true);
    expect(withDeleted, isNotNull);
    expect(withDeleted!.sync.isDeleted, isTrue);
  });

  test('soft delete then restore round-trips the tombstone', () async {
    await tags.insert(sampleTag());

    await tags.softDeleteByKey(_tagKey, actor: _actor);
    expect(await tags.findById('tag-1', projectId: 'project-1'), isNull);

    await tags.restoreByKey(_tagKey, actor: _actor);
    final restored = await tags.findById('tag-1', projectId: 'project-1');
    expect(restored, isNotNull);
    expect(restored!.sync.isDeleted, isFalse);
  });

  test('revision increments and updated_at advances on each mutation',
      () async {
    // Drive the base helpers with explicit `now` for deterministic timestamps.
    final base = BaseRepository(
      database.raw,
      table: Tables.tags,
      // Composite since task 11.219 — `pk` has to be the whole key or every
      // base helper builds a `WHERE` that matches the wrong project's row.
      pk: const ['tag_id', 'project_id'],
      rule: MutationRule.anyUser,
    );
    await tags.insert(sampleTag());

    final inserted = await tags.findById('tag-1', projectId: 'project-1');
    expect(inserted!.sync.revision, 0);

    final t1 = DateTime.utc(2026, 7, 16, 20, 0, 0);
    await base.updateByKey(
      _tagKey,
      {'tag_name': 'Renamed'},
      actor: _actor,
      now: t1,
    );

    final afterUpdate = await tags.findById('tag-1', projectId: 'project-1');
    expect(afterUpdate!.sync.revision, 1);
    expect(afterUpdate.tagName, 'Renamed');
    expect(afterUpdate.sync.updatedAt, t1);

    final t2 = DateTime.utc(2026, 7, 16, 21, 0, 0);
    await base.softDeleteByKey(_tagKey, actor: _actor, now: t2);

    final afterDelete = await tags.findById('tag-1', projectId: 'project-1', includeDeleted: true);
    expect(afterDelete!.sync.revision, 2);
    expect(afterDelete.sync.deletedAt, t2);
    expect(afterDelete.sync.updatedAt, t2);
  });

  test('updateById does not clobber created_at or resurrect a tombstone',
      () async {
    final base = BaseRepository(
      database.raw,
      table: Tables.tags,
      // Composite since task 11.219 — `pk` has to be the whole key or every
      // base helper builds a `WHERE` that matches the wrong project's row.
      pk: const ['tag_id', 'project_id'],
      rule: MutationRule.anyUser,
    );
    await tags.insert(sampleTag());
    final created = (await tags.findById('tag-1', projectId: 'project-1'))!.sync.createdAt;

    // Attempt to overwrite managed columns via the update map — must be ignored.
    final affected = await base.updateByKey(
      _tagKey,
      {
        'tag_name': 'X',
        'created_at': DateTime.utc(1999).toIso8601String(),
        'revision': 999,
      },
      actor: _actor,
      now: DateTime.utc(2026, 7, 16, 22),
    );
    expect(affected, 1);

    final after = await tags.findById('tag-1', projectId: 'project-1');
    expect(after!.sync.createdAt, created, reason: 'created_at preserved');
    expect(after.sync.revision, 1, reason: 'revision managed by repo, not caller');

    // Update on a tombstoned row is a no-op.
    await base.softDeleteByKey(
      _tagKey,
      actor: _actor,
      now: DateTime.utc(2026, 7, 16, 23),
    );
    final affectedAfterDelete =
        await base.updateByKey(
      _tagKey,
      {'tag_name': 'Y'},
      actor: _actor,
      now: DateTime.utc(2026),
    );
    expect(affectedAfterDelete, 0);
  });
}

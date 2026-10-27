import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/tag_library_repository.dart';

import '../fixtures.dart';

/// Task 11.288: the Tag Library gained a delete, and this is the repository
/// half of it — `findAll`'s existing `deleted_at IS NULL` filter needed no
/// change, so what is new is [TagLibraryRepository.softDelete] and its undo,
/// [TagLibraryRepository.restore].
void main() {
  late AppDatabase database;
  late TagLibraryRepository repo;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    repo = TagLibraryRepository(database.raw);
  });

  tearDown(() async {
    await database.close();
  });

  test('a soft-deleted entry drops out of findAll but not out of the table',
      () async {
    await repo.insert(sampleTagLibraryEntry(id: 'a'));
    await repo.insert(sampleTagLibraryEntry(id: 'b', lineageId: 'tag-2'));

    await repo.softDelete(['a']);

    expect((await repo.findAll()).map((e) => e.tagId), ['b']);
    expect(
      (await repo.findAll(includeDeleted: true)).map((e) => e.tagId),
      containsAll(['a', 'b']),
      reason: 'the row is a tombstone, not gone — that is what makes undo '
          'a plain column write rather than a reconstruction',
    );
  });

  test('softDelete bumps revision, once per row, and touches only the rows '
      'named', () async {
    await repo.insert(sampleTagLibraryEntry(id: 'a'));
    await repo.insert(sampleTagLibraryEntry(id: 'b', lineageId: 'tag-2'));

    await repo.softDelete(['a']);

    final a = (await repo.findById('a', includeDeleted: true))!;
    final b = (await repo.findById('b'))!;
    expect(a.sync.revision, 1, reason: 'inserted at 0, deleted bumps to 1');
    expect(a.sync.deletedAt, isNotNull);
    expect(b.sync.revision, 0, reason: 'an untouched row keeps its revision');
    expect(b.sync.deletedAt, isNull);
  });

  test('restore clears the tombstone and bumps revision again', () async {
    await repo.insert(sampleTagLibraryEntry(id: 'a'));
    await repo.softDelete(['a']);

    await repo.restore(['a']);

    final restored = (await repo.findById('a'))!;
    expect(restored.sync.deletedAt, isNull);
    expect(restored.sync.revision, 2);
    expect((await repo.findAll()).map((e) => e.tagId), ['a']);
  });

  test('softDelete on several ids at once deletes exactly those', () async {
    await repo.insert(sampleTagLibraryEntry(id: 'a'));
    await repo.insert(sampleTagLibraryEntry(id: 'b', lineageId: 'tag-2'));
    await repo.insert(sampleTagLibraryEntry(id: 'c', lineageId: 'tag-3'));

    await repo.softDelete(['a', 'c']);

    expect((await repo.findAll()).map((e) => e.tagId), ['b']);
  });

  test('entryCount still counts a soft-deleted entry — the round-robin '
      'colour position does not rewind', () async {
    await repo.insert(sampleTagLibraryEntry(id: 'a'));
    await repo.insert(sampleTagLibraryEntry(id: 'b', lineageId: 'tag-2'));
    expect(await repo.entryCount(), 2);

    await repo.softDelete(['a', 'b']);

    expect(
      await repo.entryCount(),
      2,
      reason: 'a colour still shown on a project\'s map must not be handed '
          'straight back out to the next new entry',
    );
  });

  test('softDelete and restore with an empty list are no-ops', () async {
    await repo.insert(sampleTagLibraryEntry(id: 'a'));

    await repo.softDelete([]);
    await repo.restore([]);

    expect((await repo.findAll()).map((e) => e.tagId), ['a']);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/csv/tag_csv_commit.dart';
import 'package:tritrack/data/csv/tag_csv_import.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart' show kTagLibraryTable;
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// Finding **M-2** (security model §14.9): the tag CSV commit loop was
/// unguarded and untransacted, so one rejected row left a partial import with
/// no rollback and no message — the success snackbar was never reached.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const project = 'project-1';
  final now = DateTime.utc(2026, 8, 16, 12);

  late AppDatabase database;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    await database.raw.insert(Tables.users, sampleUser().toColumns());
    await database.raw.insert(Tables.projects, sampleProject(id: project).toColumns());
  });
  tearDown(() async => database.close());

  /// Tags **in the project**. Since task 11.219 a CSV import writes two
  /// kinds of row — a library entry per collar, and a copy of it in the
  /// project — so the two are counted separately below.
  Future<int> tagCount() async =>
      (await database.raw.rawQuery('SELECT COUNT(*) AS c FROM ${Tables.tags}'))
          .first['c']! as int;

  Future<int> libraryCount() async =>
      (await database.raw.rawQuery('SELECT COUNT(*) AS c FROM $kTagLibraryTable'))
          .first['c']! as int;

  Future<int> commit(TagCsvPreview preview) => TagCsvCommit.commit(
        database.raw,
        preview,
        projectId: project,
        modifiedBy: 'user-1',
        deviceId: 'device-A',
        now: now,
      );

  test('a whole valid file commits, library entries and project copies '
      'together', () async {
    const csv = 'frequency_mhz,tag_name,date_put_on\n'
        '150.1,A,2026-01-15\n'
        '150.2,B,2026-01-15\n'
        '150.3,C,2026-01-15\n';

    expect(await commit(TagCsvImport.preview(csv)), 3);
    expect(await libraryCount(), 3);
    expect(await tagCount(), 3);
    // Each project copy carries its library entry's lineage — that is what
    // says the two rows are one collar (task 11.219, §2.3).
    final lineages = (await database.raw.query(Tables.tags))
        .map((r) => r['lineage_id'])
        .toSet();
    final entryLineages = (await database.raw.query(kTagLibraryTable))
        .map((r) => r['lineage_id'])
        .toSet();
    expect(lineages, entryLineages);
  });

  test('one row the database rejects leaves nothing behind', () async {
    const csv = 'frequency_mhz,tag_name,date_put_on\n'
        '150.1,A,2026-01-15\n'
        '150.2,B,2026-01-15\n'
        '150.3,C,2026-01-15\n';
    final preview = TagCsvImport.preview(csv);

    // The rejection M-2 names, arranged rather than waited for: the third
    // row's id already exists, so `ConflictAlgorithm.abort` throws — which is
    // the same throw a `NaN` frequency reaching a `REAL NOT NULL` column
    // produces (finding M-1), from the middle of the loop.
    final collide = preview.rows.last
        .withSync(now: now, modifiedBy: 'user-1', deviceId: 'device-A');
    await database.raw.insert(kTagLibraryTable, collide.toColumns());
    final before = await libraryCount();

    await expectLater(commit(preview), throwsA(isA<DatabaseException>()));

    expect(await libraryCount(), before,
        reason: 'the rows before the failure must not survive it — a partial '
            'import with no report is the finding');
    expect(await tagCount(), 0,
        reason: 'and neither must the project copies, which is the half task '
            '11.219 added: a viewer importing two hundred tags into a project '
            'they may not write must not be left with two hundred library '
            'entries and no tags, reported as a success');
  });

  test('a preview with no valid rows writes nothing and does not throw',
      () async {
    const csv = 'frequency_mhz,tag_name,date_put_on\n'
        'not-a-number,A,2026-01-15\n';
    final preview = TagCsvImport.preview(csv);

    expect(preview.validRows, isEmpty);
    expect(await commit(preview), 0);
    expect(await tagCount(), 0);
    expect(await libraryCount(), 0);
  });

  test('a skipped row (task 11.13) is not written', () async {
    const csv = 'frequency_mhz,tag_name,date_put_on\n'
        '150.1,A,2026-01-15\n'
        '150.2,B,2026-01-15\n'
        '150.3,C,2026-01-15\n';
    final preview = TagCsvImport.preview(csv);
    final skippedRow = preview.rows[1].rowNumber;

    final written = await TagCsvCommit.commit(
      database.raw,
      preview,
      projectId: project,
      modifiedBy: 'user-1',
      deviceId: 'device-A',
      now: now,
      skippedRowNumbers: {skippedRow},
    );

    expect(written, 2);
    expect(await tagCount(), 2);
    expect(await libraryCount(), 2);
    final names = (await database.raw.query(Tables.tags))
        .map((r) => r['tag_name'])
        .toSet();
    expect(names, {'A', 'C'});
  });

  test('with no active project the collars land in the library and in no '
      'project', () async {
    // **The shape of this changed with task 11.219 and the change is the
    // point.** A spreadsheet describes the person's transmitters, so it goes
    // into their library; putting a copy in a project is a separate act with
    // the project's role gradient in front of it. Before copy-on-add the
    // same import wrote a global tag and no link, which is a tag belonging
    // to nobody.
    const csv = 'frequency_mhz,tag_name,date_put_on\n150.1,A,2026-01-15\n';

    final written = await TagCsvCommit.commit(
      database.raw,
      TagCsvImport.preview(csv),
      projectId: null,
      modifiedBy: 'user-1',
      deviceId: 'device-A',
      now: now,
    );

    expect(written, 1);
    expect(await libraryCount(), 1);
    expect(await tagCount(), 0);
  });
}

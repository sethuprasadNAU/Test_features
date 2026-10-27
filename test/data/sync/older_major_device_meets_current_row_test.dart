import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **What happens on a device one major behind when a current server hands it
/// a tag row** — the measurement that owes every major bump its price.
///
/// **Renamed from `v15_device_meets_v16_row_test.dart` by task 11.243**, and
/// the rename is the point: task 11.242 wrote it about the v15/v16 pair
/// specifically, and 11.243 spent major 5, so a file named after two schema
/// versions would have had to be rewritten or abandoned at every bump. The
/// two versions are **derived** now —  is the last minor of the
/// previous major, and the current one is whatever  builds — so
/// the next bump needs no edit here at all. A reader following the old name out of task 11.242's report
/// lands here.
///
/// ## What this was written for (task 11.242, and it still holds)
///
/// Task 11.240 made `Tags.color_hex` nullable — colour moved to the animal —
/// and left `schemaMajorVersion` at 3, so a v15 app and a v16 server both
/// announced "major 3", the compatibility check let them sync, and 11.240's
/// report *said* the v15 app would then crash on the null colour. Nothing in
/// the repository demonstrated it. This file did, and the answer was a little
/// different from the sentence: **the older device fails one step earlier
/// than its model, and it fails in a way that wedges sync for good.**
///
/// ## What this can and cannot reproduce
///
/// The older *code* is not in this build. What is in this build, verbatim and
/// unchangeable, is the older *database*: shipped migrations are never edited,
/// so `runMigrations(from: 0, to: older)` produces exactly the SQLite
/// schema that phone holds. The merger's write is reproduced by hand — an
/// `INSERT` of the row's own columns, which is what `ProjectMerger` issues for
/// a row it has not seen.
///
/// ## The measured chain
///
/// 1. A current writer sends a `Tags` row (`Tag.toColumns`).
/// 2. The older merger splits off every column it has no home for as an
///    unknown column — that part works exactly as task 10.18 designed — and
///    inserts the rest.
/// 3. The older schema has a `NOT NULL` column the current row cannot
///    satisfy, so SQLite refuses the row. **This is where it stops**, before
///    any model reads a value.
/// 4. The whole page is one transaction, so nothing on that page is stored.
/// 5. The exception is not a `SyncTransportException`, so
///    `sync_provider.dart`'s catch-all records it as
///    `SyncFailureCause.deviceFault` and the cursor does not move.
/// 6. Every later sync requests the same page, hits the same row, and fails
///    the same way. The person eventually reads *"Sync has failed repeatedly.
///    If this continues, contact whoever manages your project server"* —
///    advice pointing at the one party who cannot help, for a problem fixed
///    by updating the app.
///
/// Step 3 is the crash. Step 6 is why it matters more than a crash: an app
/// that fell over would at least look broken. This one looks like a server
/// problem, forever, on a phone that may be holding a season of bearings.
///
/// **Which column it is changes with the bump, and the test derives it rather
/// than naming one.** At major 4 it was `color_hex` losing `NOT NULL`; at
/// major 5 it is `date_put_on`, `NOT NULL` on the older schema and **gone**
/// from the current one, which is a different one of the nine kinds of change
/// arriving at the same wreck. Asserting the column by name would have made
/// this file a task-11.242 artefact; asserting *that there is one* is the
/// claim the boundary rests on.
///
/// ## Why this still exists after each fix
///
/// Each bump **refuses** the older device before any row is exchanged
/// (`version_skew_test.dart`, `sync_transport_refusal_test.dart`, and the e2e
/// suite hold that). This file holds the *reason* the bump was owed: the
/// older schema is fixed forever, and if anyone ever argues the two builds
/// were compatible, the answer is a green run of this file. It is also the
/// fixture the class check in `wire_shape_freeze.dart` was derived from.
/// **Major 6 (task 11.323) moved the subject off `Tags`**, and this file had
/// said the next bump would need no edit — true of the *versions*, which it
/// derives, and false of the *table*, which it had named: at major 6 the
/// incompatible column is `Estimated_Positions.semi_major_axis`, losing
/// `NOT NULL` (an estimate with no ellipse), and every check here was still
/// asking about tags and found nothing. **So the subject is now one line per
/// major, in [_subjects]**, and a major with no line fails here by name
/// rather than measuring a table its bump did not touch.
void main() {
  /// The last schema version of the **previous** major — the newest database
  /// a device one major behind can be holding.
  final older = schemaMajorFirstMinor[schemaMajorVersion]! - 1;
  final subject = _subjects[schemaMajorVersion];

  late Database old;

  setUp(() async {
    sqfliteFfiInit();
    old = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: older, singleInstance: false),
    );
    // That phone, exactly: the shipped migrations up to and including its
    // last version and not one further.
    await runMigrations(old, from: 0, to: older);
    await old.execute('PRAGMA foreign_keys = ON');
    // The row's project, owner and collar, so the foreign keys that phone
    // enforces are satisfied and the only thing under test is the shape.
    await old.insert(Tables.users, {
      'user_id': 'user-1',
      'email': 'michael@example.invalid',
      'first_name': 'Michael',
      'last_name': 'S',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    await old.insert(Tables.projects, {
      'project_id': 'project-1',
      'project_name': 'Ponui 2026',
      'owner_user_id': 'user-1',
      'creation_date': '2026-01-01T00:00:00Z',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    if (subject != null && subject.table != Tables.tags) {
      await old.insert(
        Tables.tags,
        await _asOlderWouldInsertInto(
          old,
          Tables.tags,
          sampleTag(id: 'tag-1').toColumns(),
        ),
      );
    }
  });

  tearDown(() => old.close());

  test('this major names the table its bump made incompatible', () {
    expect(
      subject,
      isNotNull,
      reason: 'schemaMajorVersion is $schemaMajorVersion and _subjects has no '
          'line for it. Add the table the bump changed and a current row of '
          'it, as the bumping task — the checks below then measure it.',
    );
  });
  if (subject == null) return;

  Future<Set<String>> columnsOf(String table) async {
    final info = await old.rawQuery('PRAGMA table_info($table)');
    return {for (final c in info) c['name'] as String};
  }

  /// The columns the older schema stores `NOT NULL` and the current row
  /// cannot supply — either because it sends null, or because the column is
  /// gone from the current declaration entirely.
  ///
  /// **Derived from the two schemas rather than named**, so this file stays
  /// about the boundary rather than about one bump.
  Future<List<String>> unsatisfiable(Map<String, Object?> currentRow) async {
    final info = await old.rawQuery('PRAGMA table_info(${subject.table})');
    return [
      for (final column in info)
        if (column['notnull'] == 1 &&
            column['dflt_value'] == null &&
            currentRow[column['name']] == null)
          column['name'] as String,
    ];
  }

  /// What the older merger would try to write: the current row with every
  /// column that build has no home for split off and held
  /// (`UnknownColumnStore` keeps them; they are not the subject here).
  Future<Map<String, Object?>> asOlderWouldInsert(
    Map<String, Object?> currentRow,
  ) => _asOlderWouldInsertInto(old, subject.table, currentRow);

  test('the premise: the two schemas really do differ on a NOT NULL column',
      () async {
    // Checked rather than assumed: if the older schema demanded nothing the
    // current row lacks, there would be nothing here to measure and every
    // assertion below would pass for the wrong reason.
    final blocking = await unsatisfiable(subject.row('row-1'));
    expect(
      blocking,
      isNotEmpty,
      reason:
          'a device on major ${schemaMajorVersion - 1} holds a NOT NULL '
          'column of ${subject.table} that a major-$schemaMajorVersion row '
          'cannot fill. If this is empty, either the bump was not owed or '
          'this file has stopped measuring it — find out which before '
          'deleting anything.',
    );
    expect(await columnsOf(subject.table), containsAll(blocking));
  });

  test('a current row, as a current writer sends it, cannot be stored on the '
      'older device — SQLite refuses it before any model reads it', () async {
    // Exactly what the wire carries. Nothing hand-built.
    final row = subject.row('row-2');
    final blocking = (await unsatisfiable(row)).first;

    final attempt = await asOlderWouldInsert(row);

    await expectLater(
      old.insert(subject.table, attempt),
      throwsA(
        isA<DatabaseException>().having(
          (e) => e.toString(),
          'message',
          contains('NOT NULL constraint failed: ${subject.table}.$blocking'),
        ),
      ),
    );
    expect(
      await old.query(subject.table),
      isEmpty,
      reason: 'nothing landed — the row is not half-stored',
    );
  });

  test('control: fill in what the older schema demands and it stores fine, so '
      'the missing columns are the whole of the incompatibility', () async {
    final row = subject.row('row-3');
    final attempt = await asOlderWouldInsert(row);
    for (final column in await unsatisfiable(row)) {
      attempt[column] = subject.fill(column);
    }
    await old.insert(subject.table, attempt);
    expect(await old.query(subject.table), hasLength(1));
  });

  test('an UPDATE of a row it already holds behaves as this bump predicts, '
      'and the difference is measured rather than assumed', () async {
    // **The other path into the merger.** At major 4 the incoming row
    // carried `color_hex: null`, so the UPDATE wrote the null and SQLite
    // refused it. At major 5 the blocking column was *absent* from the
    // current row (`Tags.date_put_on` deleted), so the UPDATE did not mention
    // it and landed. **At major 6 it is major 4 again**: the row carries the
    // empty ellipse, so the UPDATE writes the nulls and is refused.
    //
    // The boundary refuses these two builds before a row is exchanged, so
    // this never happens in the field; it records *where* a wrong boundary
    // would wedge — on the first edit, or only on the first new row.
    final stored = await asOlderWouldInsert(subject.row('row-4'));
    for (final column in await unsatisfiable(subject.row('row-4'))) {
      stored[column] = subject.fill(column);
    }
    await old.insert(subject.table, stored);

    final incoming = await asOlderWouldInsert(subject.row('row-4'));
    final blocking = await unsatisfiable(subject.row('row-4'));
    final carriesTheNull = blocking.any(incoming.containsKey);
    expect(
      carriesTheNull,
      subject.updateCarriesTheNull,
      reason: 'whether the current row names the blocking column at all',
    );
    final update = old.update(
      subject.table,
      incoming,
      where: subject.keyWhere,
      whereArgs: ['row-4', 'project-1'],
    );
    if (subject.updateCarriesTheNull) {
      await expectLater(update, throwsA(isA<DatabaseException>()));
    } else {
      await update;
      expect(await old.query(subject.table), hasLength(1));
    }
  });
}

/// What the older merger would write into [table]: [currentRow] with every
/// column the older database [db] has no home for split off.
Future<Map<String, Object?>> _asOlderWouldInsertInto(
  Database db,
  String table,
  Map<String, Object?> currentRow,
) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  final columns = {for (final c in info) c['name'] as String};
  return {
    for (final entry in currentRow.entries)
      if (columns.contains(entry.key)) entry.key: entry.value,
  };
}

/// One bump's subject: the table it made incompatible and a current row of
/// it, as a current writer sends it.
class _Subject {
  const _Subject({
    required this.table,
    required this.row,
    required this.keyWhere,
    required this.fill,
    required this.updateCarriesTheNull,
  });
  final String table;
  final Map<String, Object?> Function(String id) row;
  final String keyWhere;

  /// A value of the right shape for a blocking column — the point is only
  /// that *something* is there; the absence is what makes the row unstorable.
  final Object? Function(String column) fill;

  /// Whether the current row *names* the blocking column (with a null), so
  /// an UPDATE writes the null; or omits it, so an UPDATE leaves it alone.
  final bool updateCarriesTheNull;
}

/// **One line per major since this file was generalised.** The earlier
/// majors' subjects are history and need no line: the file only ever
/// measures the boundary the current build sits on.
final Map<int, _Subject> _subjects = {
  // Task 11.323: an estimate with no ellipse.
  6: _Subject(
    table: Tables.estimatedPositions,
    row: (id) => sampleEstimatedPosition(id: id, tagId: 'tag-1')
        .copyWith(semiMajorAxis: null, semiMinorAxis: null, rotationAngle: null)
        .toColumns(),
    keyWhere: 'position_id = ? AND project_id = ?',
    fill: (column) => 1.0,
    updateCarriesTheNull: true,
  ),
};

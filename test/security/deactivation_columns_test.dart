import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Finding **L-12** (security model §14.9), as a class rather than as
/// `end_date`.
///
/// `UntrustedImportRules.isDestructiveChange` enumerated `deleted_at` by hand,
/// so an archive setting `Project_Memberships.end_date` applied with
/// `destructiveChanges = 0` and no consent dialog. The predicate now derives
/// from `SyncTable.deactivationColumns`. **A declared set that nobody keeps
/// current is the hand-written name with extra ceremony**, so this file is the
/// keeping-current: it checks that every declared entry is real, and it sweeps
/// the repository layer for the shape a *new* deactivation column would have.
void main() {
  test('every declared deactivation column exists and can actually arrive', () {
    // Called here rather than only at runtime for the same reason
    // `assertEveryEmailColumnHasASubject` is: a build-time conversation beats
    // a fail-closed surprise in the field.
    expect(assertEveryDeactivationColumnExists, returnsNormally);
  });

  test('every table declares the universal soft-delete column', () {
    for (final table in syncTables) {
      expect(table.deactivationColumns, contains('deleted_at'),
          reason: table.name);
    }
  });

  test('the sweep: every column the repository layer treats as a visibility '
      'gate is declared', () {
    // The shape a deactivation column has in this codebase is a
    // `<column> IS NULL` clause in a read — that is what
    // `ProjectMembershipRepository`'s "current means end_date IS NULL" looks
    // like, and it is what `deleted_at` looks like in `BaseRepository`. A new
    // one lands as a new `IS NULL` filter, so that is what this greps for.
    //
    // Anything found and not declared is either a real L-12 or a considered
    // exclusion — and an exclusion has to be written down here, which is
    // §5 rule 4 ("silence is not a disposition") applied to a test.
    const consideredAndExcluded = <String>{
      // Not a visibility gate: `_buildUserRemap`'s tier-2a filter reads live
      // `User_Emails` rows, and a prior address arriving does not hide the
      // user — it is an addition, which the ordinary `was != null` test
      // already handles correctly.
    };

    final declared = {
      for (final table in syncTables) ...table.deactivationColumns,
    };
    final found = <String, List<String>>{};
    final pattern = RegExp(r'(\w+) IS NULL');
    for (final entity in Directory('lib/data/repositories').listSync()) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      for (final line in entity.readAsLinesSync()) {
        // **`IS NULL` in an ORDER BY is a sort key, not a gate** — task
        // 11.243. `DeploymentRepository` orders by
        // `attached_date IS NULL, attached_date` so a deployment nobody
        // dated sorts last instead of first, which is SQLite's default and
        // is not what a person is looking for. It hides no row.
        //
        // **Excluded by where it appears rather than by its name**, which is
        // the difference that matters: naming `attached_date` in
        // `consideredAndExcluded` would also excuse a future
        // `where: 'attached_date IS NULL'` — a real gate — and nothing would
        // say so. This exclusion cannot cover one, because a `where:` clause
        // is still swept.
        if (line.contains('orderBy:')) continue;
        for (final match in pattern.allMatches(line)) {
          final column = match.group(1)!;
          if (declared.contains(column)) continue;
          if (consideredAndExcluded.contains(column)) continue;
          found.putIfAbsent(column, () => []).add(entity.path);
        }
      }
    }

    expect(found, isEmpty,
        reason: 'a column filtered as "still live" and not declared in '
            'SyncTable.deactivationColumns is finding L-12 again — declare '
            'it, or record why it is not a deactivation in this test');
  });

  test('the sweep can fail — it finds the shape it is looking for', () {
    // Four instruments that could not fail have been rejected by this gate
    // (H-2, I-3, J-6, K-9). Run the detector against the exact clause
    // `ProjectMembershipRepository` carries, so an inert regex is caught here
    // rather than at the next gate.
    final pattern = RegExp(r'(\w+) IS NULL');
    final match = pattern.firstMatch(
        "where: 'project_id = ? AND user_id = ? AND end_date IS NULL',");
    expect(match?.group(1), 'end_date');
    // And that the ORDER BY exclusion above is about the clause and not
    // about the column: the same column in a `where:` is still found.
    const gate = "where: 'attached_date IS NULL',";
    expect(gate.contains('orderBy:'), isFalse);
    expect(pattern.firstMatch(gate)?.group(1), 'attached_date');
  });

  test('a NOT NULL column cannot be declared, because it can never arrive', () {
    // The criterion is the null → non-null transition. A `status` column is
    // `NOT NULL`, so deactivating through one always *replaces* a value and
    // the ordinary predicate already catches it — declaring one here would
    // state something about the schema that is not true.
    for (final table in syncTables) {
      final spec = tableSpecsByName[table.name]!;
      for (final column in table.deactivationColumns) {
        final declared = spec.columns.firstWhere((c) => c.name == column);
        expect(spec.isNotNull(declared), isFalse, reason: '${table.name}.$column');
      }
    }
  });

  test('deactivating through a NOT NULL status column is destructive anyway',
      () {
    // Stated as a test rather than trusted, because it is the reason
    // `Tags.status` and `Project_Tags.status` are *absent* from the declared
    // set — and an absence with no test behind it is how L-12 happened.
    expect(
      UntrustedImportRules.isDestructiveChange(
        table: Tables.projectTags,
        column: 'status',
        was: 'active',
        becomes: 'removed',
      ),
      isTrue,
    );
  });
}

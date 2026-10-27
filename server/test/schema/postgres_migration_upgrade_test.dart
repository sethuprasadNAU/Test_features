@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// **Task 11.16.** Every schema migration up to now has been exercised only by
/// building a database from scratch — `postgres_schema_test.dart` checks the
/// generated DDL as strings, and `PostgresMigrations.run` bootstrapping a fresh
/// `public` schema is what every other Postgres-backed test file does in its
/// `setUp`. Nothing has ever run a migration *against a populated database* and
/// checked that the rows already there survived it.
///
/// That gap matters starting now, not eventually: the beta server holds data
/// — five collars on schema v11, measured by Michael's census on 2026-09-11;
/// whether they are a field season or seeded rows is his to say — and it gets
/// upgraded while that data is live in it. A migration that finishes without
/// throwing is not the same
/// claim as a migration that left every existing row's values untouched — a
/// rebuild that quietly drops a column, or a backfill that computes the wrong
/// value, completes cleanly and corrupts data anyway. This file is the harness
/// for catching that class. It began with the two migrations available at the
/// time — v7 (`Observation_Exclusions`, task 11.7) and v8 (the one-open-
/// membership index, task 11.10) — gained v9 (`Tag_Versions`, task 11.32),
/// and since task 11.222 covers v14 (the tag re-key, task 11.219). **Task
/// 11.227 widened that group to v11 → v15**, because the census said the beta
/// server is on v11 rather than the v13 everybody had assumed — so the path
/// its data will actually take crosses v12 and v13 as well.
///
/// ## Two techniques for reaching an older shape, and which one this file uses
///
/// Every group needs a database in the shape the migration under test
/// expects to find. There are two ways to get one, and the choice matters
/// more than it looks, because the *next* non-additive migration will copy
/// whichever this file does.
///
/// **Reconstruct backwards**: bootstrap the *current* schema with
/// `PostgresMigrations.run`, then hand-write the statements that undo the
/// later migrations. This is what every group here does. Its virtue is that
/// every table the migration does not touch starts in its real, current
/// shape — derived from `tableSpecs`, not copied — so there is only one
/// hand-written thing per group and it sits beside the migration it inverts,
/// where a reader can check it statement against statement. Its cost is that
/// the inverse is hand-written, and that it compounds: after a second
/// re-keying migration, this group's `setUp` would have to invert *that one
/// too* before it could invert v14, and the v9 group's patch (below) would
/// need re-examining. Task 11.220 met the first sign of this when v14 broke
/// the v9 group's `setUp`.
///
/// **Replay forwards**: commit a DDL snapshot of the old shape (a
/// `pg_dump --schema-only` of a v11 database, say) and run the real
/// migrations over it. This is what most projects end up with. Its virtue is
/// that a snapshot of v11 is frozen — v11 never changes again, so the
/// snapshot never needs maintaining, and one snapshot serves every later
/// group. Its cost is that it is three hundred lines of a shape no file in
/// this repository describes, its only reader is Postgres, and it is a copy
/// of something that once existed — which is the shape this project has been
/// bitten by more than once.
///
/// **Neither is checkable on its own, and that was the actual gap.** A
/// hand-written inverse and a committed snapshot are both hand-kept text;
/// what makes either honest is a check that neither had: **migrate the old
/// shape forward through every real migration and compare the resulting
/// catalog — columns, keys, foreign keys, indexes — against a fresh
/// bootstrap.** If the reconstruction is wrong, the migrated result differs
/// from the bootstrap. If the *migration* is wrong — builds something the
/// bootstrap does not, or forgets something it does — the same check goes
/// red, which is a property nobody had ever tested and which
/// `schemaStatements`' own doc comment worries about for v8. The v11 → v15
/// group below has that oracle. It is the reusable half of this decision.
///
/// **So: reconstruct backwards, with the oracle, for now — and the trigger
/// for switching is written here rather than left to be rediscovered.** The
/// day a second migration re-keys a table, the inverse this group would need
/// becomes an inverse of two migrations, and that is the day a frozen v11
/// snapshot is cheaper than the inverse. The oracle written here is exactly
/// the check that snapshot would be validated by, so switching costs the
/// snapshot and nothing else. Until then, one technique in one file.
///
/// **Task 11.226 gave the v7, v8 and v9 groups the same oracle**, via
/// `catalogOf`/`expectMigratedCatalogMatchesBootstrap`, hoisted to file scope
/// so all four groups share one check. It confirmed the v9 patch's
/// approximation the comment beside it already named: the reconstruction's
/// `tags_tag_id_unique_for_v9_replay` constraint has no counterpart in a
/// fresh bootstrap, and that one line is the oracle's only documented
/// exclusion.
///
/// **v6 (task 10.35's primary-key rekey, the one genuinely risky rebuild in
/// the set) is deliberately not included here.** Reconstructing its
/// pre-migration shape — single-column primary keys on six tables, which
/// nothing in the current codebase still describes since `tableSpecs` is the
/// *current* schema — would mean hand-writing historical DDL with no source of
/// truth to check it against. That migration's own doc comment records why the
/// cost of getting it wrong was accepted at the time: it was "spent while
/// nothing was deployed," i.e. no server ever ran it against a populated
/// database, and none ever will now that it has already shipped. The residual
/// risk that matters going forward is a *future* migration run against real
/// data, which is exactly what v7 and v8 already demonstrate the harness
/// catching. Flagged rather than silently skipped — see this task's report for
/// the recommendation.
/// The last schema version before task 11.243's wipe. **Derived from
/// `schemaMajorFirstMinor` rather than typed**, because major 5 begins at the
/// wipe — so this stays correct when a later minor lands, and goes red rather
/// than silently wrong if somebody moves where the major starts.
final int _lastVersionBeforeTheWipe = schemaMajorFirstMinor[5]! - 1;

void main() {
  late Connection connection;
  const testSchema = 'tritrack_migration_upgrade_test';
  const at = '2026-08-01T00:00:00.000Z';

  setUpAll(() async {
    if (testDatabaseConfig == null) return;
    connection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.close();
  });

  setUp(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    // Builds the *current* schema. Each group below then strips off whichever
    // later changes it wants to test migrating back through, so the starting
    // DDL for every other table is always the real, current one rather than
    // a hand-maintained duplicate that could itself drift.
    await PostgresMigrations.run(connection);
  });

  /// Seeds one representative row in every table a migration is not supposed
  /// to touch: a user, a project, two memberships (one open, one already
  /// ended — the shape [isOpenOwnerMembership] and the v8 index both care
  /// about), a tag, and an observation. Not every one of the shared tables —
  /// the ones chosen span every column type migrations in this file touch
  /// (text, real, integer, nullable).
  ///
  /// **This list used to claim it spanned "both of the FK-bearing shapes
  /// (project-scoped and global)", and since task 11.219 it does not.** `Tags`
  /// was the global one and it is project-scoped now, so every FK-bearing
  /// table in this seed is project-scoped. The two globally-keyed tables left
  /// in the schema are `Users` (seeded, and referenced by nothing here) and
  /// `User_Emails` (not seeded). Recorded rather than silently corrected,
  /// because "the seed spans both shapes" is the kind of sentence a later
  /// reader would take as still true.
  Future<void> seedRepresentativeData() async {
    await connection.runTx((tx) async {
      await tx.execute(
        'INSERT INTO ${quoted(Tables.users)} '
        '(user_id, first_name, last_name, email, created_at, updated_at, '
        'revision) '
        r"VALUES ('user-1', 'Sam', 'Ranger', 'sam@example.com', $1, $1, 0)",
        parameters: [at],
      );
      await tx.execute(
        'INSERT INTO ${quoted(Tables.projects)} '
        '(project_id, project_name, owner_user_id, creation_date, datum, '
        'created_at, updated_at, revision, coordinate_format, '
        'triangulation_window_minutes) '
        r"VALUES ('proj-1', 'Peaks', 'user-1', $1, 'WGS84', $1, $1, 0, 'dd', 15)",
        parameters: [at],
      );
      await tx.execute(
        'INSERT INTO ${quoted(Tables.projectMemberships)} '
        '(membership_id, project_id, user_id, join_date, end_date, role, '
        'created_at, updated_at, revision, last_modified_by) '
        r"VALUES ('mem-open', 'proj-1', 'user-1', $1, NULL, 'owner', "
        r"$1, $1, 0, 'user-1')",
        parameters: [at],
      );
      await tx.execute(
        'INSERT INTO ${quoted(Tables.projectMemberships)} '
        '(membership_id, project_id, user_id, join_date, end_date, role, '
        'created_at, updated_at, revision, last_modified_by) '
        r"VALUES ('mem-ended', 'proj-1', 'user-1', $1, $1, 'contributor', "
        r"$1, $1, 0, 'user-1')",
        parameters: [at],
      );
      await tx.execute(
        // `project_id` and `lineage_id` since task 11.219 (v14): a tag
        // belongs to one project, and both columns are NOT NULL.
        // `date_put_on` left the table at v17 (task 11.243) — this seed
        // writes into the *current* schema, which the `setUp` above builds.
        'INSERT INTO ${quoted(Tables.tags)} '
        '(tag_id, project_id, lineage_id, frequency_mhz, tag_name, '
        'status, color_hex, created_at, updated_at, revision) '
        r"VALUES ('tag-1', 'proj-1', 'tag-1', 150.125, 'Goshawk 12', "
        r"'active', '#FF0000', $1, $1, 0)",
        parameters: [at],
      );
      await tx.execute(
        'INSERT INTO ${quoted(Tables.observations)} '
        '(observation_id, project_id, user_id, tag_id, timestamp_local, '
        'timestamp_utc, timezone_offset, latitude, longitude, '
        'position_source, elevation, altitude_agl, observation_type, '
        'magnetic_bearing, signal_type, signal_strength, notes, '
        'created_at, updated_at, revision) '
        r"VALUES ('obs-1', 'proj-1', 'user-1', 'tag-1', $1, $1, '-07:00', "
        r"35.19, -111.62, 'gps_fix', 2103.0, 0.0, 'directional', 145.0, "
        r"'pulse', 'strong', 'strong steady pulse', $1, $1, 3)",
        parameters: [at],
      );
    });
  }

  /// The shape of the database, as the catalog reports it: every column
  /// with its type and nullability, every constraint with its definition,
  /// every index with its definition. Schema-qualified names are
  /// stripped so two schemas holding the same shape compare equal.
  ///
  /// Shared by every group below — task 11.222 wrote it for v11 → v15 and
  /// task 11.226 hoisted it here so v7, v8 and v9 use the same check rather
  /// than a copy apiece.
  Future<List<String>> catalogOf(String schema) async {
    await connection.execute('SET search_path TO $schema');
    final lines = <String>[];
    final columns = await connection.execute(
      'SELECT table_name, column_name, data_type, is_nullable, '
      'coalesce(column_default, \'\') FROM information_schema.columns '
      r'WHERE table_schema = $1',
      parameters: [schema],
    );
    for (final row in columns) {
      lines.add('column ${row.toList().join(' ')}');
    }
    final constraints = await connection.execute(
      'SELECT conrelid::regclass::text, conname, pg_get_constraintdef(oid) '
      r'FROM pg_constraint WHERE connamespace = $1::regnamespace',
      parameters: [schema],
    );
    for (final row in constraints) {
      lines.add('constraint ${row.toList().join(' ')}');
    }
    final indexes = await connection.execute(
      'SELECT indexname, indexdef FROM pg_indexes '
      r'WHERE schemaname = $1',
      parameters: [schema],
    );
    for (final row in indexes) {
      lines.add(
        'index ${row.toList().join(' ').replaceAll('$schema.', '')}',
      );
    }
    lines.sort();
    return lines;
  }

  /// Migrates the schema-under-test forward against a fresh bootstrap's
  /// catalog. `expectedExclusions` names lines that are allowed to survive in
  /// [migrated] but not [bootstrapped] — a documented, narrow approximation
  /// left behind by this file's reconstruction technique, never a way to
  /// paper over a genuine mismatch.
  Future<void> expectMigratedCatalogMatchesBootstrap({
    List<String> expectedExclusions = const [],
  }) async {
    final migrated = await catalogOf(testSchema);

    const oracleSchema = '${testSchema}_oracle';
    await connection.execute('DROP SCHEMA IF EXISTS $oracleSchema CASCADE');
    await connection.execute('CREATE SCHEMA $oracleSchema');
    await connection.execute('SET search_path TO $oracleSchema');
    await PostgresMigrations.run(connection);
    final bootstrapped = await catalogOf(oracleSchema);
    await connection.execute('DROP SCHEMA $oracleSchema CASCADE');
    await connection.execute('SET search_path TO $testSchema');

    expect(migrated, isNotEmpty);
    final withoutExclusions = [
      for (final line in migrated)
        if (!expectedExclusions.contains(line)) line,
    ];
    expect(withoutExclusions, bootstrapped);
  }

  final snapshotTables = [
    Tables.users,
    Tables.projects,
    Tables.projectMemberships,
    Tables.tags,
    Tables.observations,
  ];

  /// Every row of every table in [snapshotTables], as column maps, ordered by
  /// primary key so two snapshots compare deterministically.
  Future<Map<String, List<Map<String, Object?>>>> snapshot() async {
    final result = <String, List<Map<String, Object?>>>{};
    for (final table in snapshotTables) {
      final spec = tableSpecsByName[table]!;
      final orderBy = spec.primaryKeyColumns.map((c) => c.name).join(', ');
      final rows = await connection.execute(
        'SELECT * FROM ${quoted(table)} ORDER BY $orderBy',
      );
      result[table] = [for (final row in rows) row.toColumnMap()];
    }
    return result;
  }

  group(
    'v6 to v7 (task 11.7): Observation_Exclusions',
    skip: databaseSkipReason,
    () {
      setUp(() async {
        // Strip v7 and v8's additions back off the fresh v8 bootstrap, landing
        // on a v6-shaped database — see the file doc comment for why v6 itself
        // isn't reconstructed further back than this.
        await connection.execute(
          'DROP TABLE ${quoted(Tables.observationExclusions)} CASCADE',
        );
        await connection.execute(
          'DROP INDEX ${quoted('idx_memberships_one_open')}',
        );
        await connection.execute(
          'DELETE FROM schema_migrations WHERE version > 6',
        );
      });

      test(
        'every existing row in every other table is untouched, byte for byte',
        () async {
          await seedRepresentativeData();
          final before = await snapshot();

          for (final statement in schemaV7Statements()) {
            await connection.execute(statement);
          }

          final after = await snapshot();
          expect(after, before);
        },
      );

      test(
        'the new table exists and actually works after the upgrade',
        () async {
          await seedRepresentativeData();
          for (final statement in schemaV7Statements()) {
            await connection.execute(statement);
          }

          await connection.execute(
            'INSERT INTO ${quoted(Tables.observationExclusions)} '
            '(exclusion_id, project_id, observation_id, user_id, kind, '
            'created_at, updated_at, revision) '
            r"VALUES ('excl-1', 'proj-1', 'obs-1', 'user-1', 'exclude', "
            r'$1, $1, 0)',
            parameters: [at],
          );
          final rows = await connection.execute(
            'SELECT kind FROM ${quoted(Tables.observationExclusions)} '
            r"WHERE exclusion_id = 'excl-1'",
          );
          expect(rows.single.first, 'exclude');
        },
      );

      test(
        'oracle: a reconstructed v6 database, upgraded, has exactly the '
        'shape a fresh bootstrap builds',
        () async {
          // This group's `setUp` strips v7's *and* v8's additions off the
          // fresh bootstrap — see the doc comment there — so both have to be
          // replayed for the result to be comparable to a full bootstrap.
          // v8's statements are not what this group exists to test; they are
          // the other half of what `setUp` removed.
          for (final statement in [
            ...schemaV7Statements(),
            ...schemaV8Statements(),
          ]) {
            await connection.execute(statement);
          }
          await expectMigratedCatalogMatchesBootstrap();
        },
      );
    },
  );

  group(
    'v7 to v8 (task 11.10): the one-open-membership index',
    skip: databaseSkipReason,
    () {
      setUp(() async {
        // Land on a v7-shaped database: the fresh bootstrap already has
        // Observation_Exclusions (v7's own content), so only v8's index needs
        // stripping.
        await connection.execute(
          'DROP INDEX ${quoted('idx_memberships_one_open')}',
        );
        await connection.execute(
          'DELETE FROM schema_migrations WHERE version > 7',
        );
      });

      test(
        'every existing row in every other table is untouched, byte for byte',
        () async {
          await seedRepresentativeData();
          final before = await snapshot();

          for (final statement in schemaV8Statements()) {
            await connection.execute(statement);
          }

          final after = await snapshot();
          expect(after, before);
        },
      );

      test(
        'the new index actually enforces the invariant after the upgrade',
        () async {
          await seedRepresentativeData();
          for (final statement in schemaV8Statements()) {
            await connection.execute(statement);
          }

          // mem-open (seeded above) already holds proj-1/user-1 open. A second
          // open row for the same pair is exactly what task 11.10 exists to
          // refuse, and it can only be proved by an upgrade that actually ran
          // against data that predates the index — a fresh bootstrap can't
          // distinguish "the index works" from "the index was never exercised
          // against a database that had a reason to violate it."
          await expectLater(
            connection.execute(
              'INSERT INTO ${quoted(Tables.projectMemberships)} '
              '(membership_id, project_id, user_id, join_date, role, '
              'created_at, updated_at, revision, last_modified_by) '
              r"VALUES ('mem-race', 'proj-1', 'user-1', $1, 'contributor', "
              r"$1, $1, 0, 'user-1')",
              parameters: [at],
            ),
            throwsA(
              isA<ServerException>().having((e) => e.code, 'SQLSTATE', '23505'),
            ),
          );
        },
      );

      test(
        'oracle: a reconstructed v7 database, upgraded, has exactly the '
        'shape a fresh bootstrap builds',
        () async {
          for (final statement in schemaV8Statements()) {
            await connection.execute(statement);
          }
          await expectMigratedCatalogMatchesBootstrap();
        },
      );
    },
  );

  group('v8 to v9 (task 11.32): Tag_Versions', skip: databaseSkipReason, () {
    setUp(() async {
      // Land on a v8-shaped database: strip v9's table and column back off the
      // fresh bootstrap.
      await connection.execute(
        'DROP TABLE ${quoted(Tables.tagVersions)} CASCADE',
      );
      await connection.execute(
        'ALTER TABLE ${quoted(Tables.observations)} DROP COLUMN tag_version_id',
      );
      await connection.execute(
        'DELETE FROM schema_migrations WHERE version > 8',
      );
      // **Task 11.219 (v14) broke this file's technique, and this line is the
      // repair plus a statement of what it does not repair.**
      //
      // The technique above is "bootstrap the current schema, then strip off
      // the later *additions*" — see this file's doc comment. Every migration
      // between v9 and v13 was an addition, so stripping worked. v14 is not
      // an addition: it re-keyed `Tags` from `(tag_id)` to
      // `(tag_id, project_id)`. `schemaV9Statements()` puts a foreign key on
      // `Tag_Versions(tag_id)` referencing `Tags(tag_id)`, and Postgres
      // refuses that against a table with no unique key on `tag_id` alone
      // (SQLSTATE 42830, watched failing before this line was added).
      //
      // A `UNIQUE (tag_id)` constraint restores **exactly the one property
      // v9's own DDL depends on** and nothing else. It deliberately does not
      // reconstruct a v8 `Tags`: the column is still there, the composite
      // primary key is still there, and the project/sequence index v14 built
      // is still there. That is the same approximation this file has always
      // made — every table other than the one under test starts in its
      // current shape — but it is now an approximation on the table under
      // test's *neighbour*, which is worth saying out loud rather than
      // leaving to be discovered.
      //
      // **What this cannot do, and what the honest limit is.** It cannot make
      // the v9 group a test of "v9 run against a real v8 database" any more,
      // because no source of truth in this repository describes a v8 `Tags` —
      // the same reason the doc comment gives for excluding v6. What it does
      // preserve is every claim the four tests below actually make: that v9's
      // statements leave existing rows byte-identical, backfill no
      // observation, invent no version, and produce a working table.
      //
      // **And a future migration that re-shapes `Tags` again will not be
      // caught by this line** — it will show up as another 42830 here, which
      // is loud, but the fix will be a decision rather than another
      // constraint. The gap underneath all of this is that v14 itself has no
      // group in this file at all; see Discovered Scope under task 11.220.
      await connection.execute(
        'ALTER TABLE ${quoted(Tables.tags)} '
        'ADD CONSTRAINT tags_tag_id_unique_for_v9_replay UNIQUE (tag_id)',
      );
    });

    test(
      'every existing row in every other table is untouched, byte for byte',
      () async {
        await seedRepresentativeData();
        final before = await snapshot();

        for (final statement in schemaV9Statements()) {
          await connection.execute(statement);
        }

        final after = await snapshot();
        // `Observations` gains a column, so its rows are compared on the
        // columns that existed before — and the new one is checked separately
        // below, because *what it holds* is the thing task 11.32 cares about.
        final carried = {
          for (final entry in after.entries)
            entry.key: [
              for (final row in entry.value)
                Map<String, Object?>.of(row)..removeWhere(
                  (column, _) =>
                      !(before[entry.key]!.first.containsKey(column)),
                ),
            ],
        };
        expect(carried, before);
      },
    );

    test('an observation that predates the upgrade is NOT backfilled — it says '
        '"not recorded", never what the tag reads today', () async {
      // The acceptance criterion, proved against a populated database rather
      // than trusted to the migration containing no UPDATE. This server
      // holds other people's records: writing a measurement context into a
      // bearing somebody else took would be inventing it on their behalf.
      await seedRepresentativeData();
      for (final statement in schemaV9Statements()) {
        await connection.execute(statement);
      }

      final rows = await connection.execute(
        'SELECT tag_version_id FROM ${quoted(Tables.observations)} '
        r"WHERE observation_id = 'obs-1'",
      );
      expect(rows.single.first, isNull);
    });

    test('no version is invented for a tag that predates the upgrade', () async {
      // Same rule, the other half. A version minted now would be a claim about
      // a past nobody observed, and the bearings that would point at it are
      // exactly the ones that must stay honest about not knowing.
      await seedRepresentativeData();
      for (final statement in schemaV9Statements()) {
        await connection.execute(statement);
      }
      final rows = await connection.execute(
        'SELECT count(*) FROM ${quoted(Tables.tagVersions)}',
      );
      expect(rows.single.first, 0);
    });

    test('the new table exists and actually works after the upgrade', () async {
      await seedRepresentativeData();
      for (final statement in schemaV9Statements()) {
        await connection.execute(statement);
      }

      await connection.execute(
        'INSERT INTO ${quoted(Tables.tagVersions)} '
        '(tag_version_id, tag_id, effective_from, frequency_mhz, tag_name, '
        'created_at, updated_at, revision) '
        r"VALUES ('ver-1', 'tag-1', $1, 150.325, 'Coco', $1, $1, 0)",
        parameters: [at],
      );
      await connection.execute(
        'UPDATE ${quoted(Tables.observations)} '
        r"SET tag_version_id = 'ver-1' WHERE observation_id = 'obs-1'",
      );
      final rows = await connection.execute(
        'SELECT v.frequency_mhz FROM ${quoted(Tables.observations)} o '
        'JOIN ${quoted(Tables.tagVersions)} v '
        'ON v.tag_version_id = o.tag_version_id '
        r"WHERE o.observation_id = 'obs-1'",
      );
      expect(rows.single.first, 150.325);
    });

    test(
      'oracle: a reconstructed v8 database, upgraded, has exactly the '
      'shape a fresh bootstrap builds',
      () async {
        for (final statement in schemaV9Statements()) {
          await connection.execute(statement);
        }
        // **Why this group cannot simply stop at `schemaV9Statements()` the
        // way v7's and v8's oracles do.** Those two groups strip nothing but
        // what their own migration adds, so replaying only that migration's
        // statements exactly restores the fresh bootstrap. This group's
        // `setUp` drops the *whole* `Tag_Versions` table (v9 built it from
        // nothing), and two later migrations went on to alter that same
        // table — v12 added the pulse-mode columns, v14 made it
        // project-scoped. `PostgresMigrations.run` cannot be asked to apply
        // just those two migrations' `Tag_Versions` statements: v12 and v14
        // also touch `Tags`, `Observations` and `Project_Tags`, which this
        // group's `setUp` never stripped, so the rest of either migration
        // would fail on columns and tables that already exist. So the
        // catch-up below is the narrowest thing that reaches a comparable
        // catalog: `Tag_Versions`' own share of v12 and v14, written out
        // statement for statement against those two migrations — the same
        // technique the v11 → v15 group uses for its full reconstruction,
        // scaled down to one table.
        for (final statement in [
          // v12's share: the five pulse-mode columns.
          for (final column in ['pulse_mode_1_name', 'pulse_mode_2_name'])
            'ALTER TABLE ${quoted(Tables.tagVersions)} ADD COLUMN $column '
                'TEXT',
          'ALTER TABLE ${quoted(Tables.tagVersions)} '
              'ADD COLUMN pulse_mode_2_rate_bpm DOUBLE PRECISION',
          'ALTER TABLE ${quoted(Tables.tagVersions)} '
              'ADD COLUMN pulse_mode_3_name TEXT',
          'ALTER TABLE ${quoted(Tables.tagVersions)} '
              'ADD COLUMN pulse_mode_3_rate_bpm DOUBLE PRECISION',
          // v14's share: project-scoping. The table is empty in this test,
          // so there is nothing for the backfilling `UPDATE`s to do — only
          // the shape matters here.
          'ALTER TABLE ${quoted(Tables.tagVersions)} '
              'DROP CONSTRAINT '
              '${quoted(foreignKeyName((Tables.tagVersions, [
                    'tag_id',
                  ], Tables.tags, ['tag_id'])))}',
          'ALTER TABLE ${quoted(Tables.tagVersions)} ADD COLUMN project_id '
              'TEXT',
          'ALTER TABLE ${quoted(Tables.tagVersions)} '
              'ALTER COLUMN project_id SET NOT NULL',
          'ALTER TABLE ${quoted(Tables.tagVersions)} '
              'DROP CONSTRAINT ${quoted('${Tables.tagVersions}_pkey')}',
          'ALTER TABLE ${quoted(Tables.tagVersions)} '
              'ADD PRIMARY KEY (tag_version_id, project_id)',
          alterAddForeignKey((
            Tables.tagVersions,
            const ['tag_id', 'project_id'],
            Tables.tags,
            const ['tag_id', 'project_id'],
          )),
          'CREATE INDEX '
              '${quoted('idx_${Tables.tagVersions}_project_seq'.toLowerCase())} '
              'ON ${quoted(Tables.tagVersions)} (project_id, server_seq)',
          'DROP INDEX ${quoted('idx_${Tables.tagVersions}_seq'.toLowerCase())}',
        ]) {
          await connection.execute(statement);
        }
        await expectMigratedCatalogMatchesBootstrap(
          expectedExclusions: [
            // This group's `setUp` adds a `UNIQUE (tag_id)` constraint to
            // `Tags` that no version of the real schema ever had — it exists
            // only so `schemaV9Statements()`'s foreign key can be created
            // against a reconstruction whose `Tags` predates v14's composite
            // key (see the comment on `tags_tag_id_unique_for_v9_replay`
            // above). A fresh bootstrap never runs `schemaV9Statements()`
            // against that reconstruction, so it never gains this
            // constraint — the exclusion is the reconstruction's known
            // approximation, not a defect in v9 itself.
            'constraint "${Tables.tags}" tags_tag_id_unique_for_v9_replay '
                'UNIQUE (tag_id)',
            // A `UNIQUE` constraint is backed by an index of the same name —
            // Postgres reports the two separately, so the exclusion above
            // does not also cover this line.
            'index tags_tag_id_unique_for_v9_replay CREATE UNIQUE INDEX '
                'tags_tag_id_unique_for_v9_replay ON "${Tables.tags}" '
                'USING btree (tag_id)',
          ],
        );
      },
    );
  });

  group(
    'v11 to v16 (tasks 11.187, 11.193, 11.219, 11.225, 11.240): the beta '
    'server\'s real upgrade path',
    skip: databaseSkipReason,
    () {
      // **Why this group starts at v11 and not at v13.** Task 11.222 wrote it
      // as v13 → v14 on the brief's word that the beta server was on v13.
      // Michael's census of that server on 2026-09-11 said **11**. So the path
      // the only real database will take is v11 → v12 → v13 → v14 → v15, and
      // v12 and v13 — both additive `ADD COLUMN` steps, the safe kind — had
      // never met a populated database either. Their expectation is written
      // down in [expectV12AndV13Additions] and checked on every path through
      // this group, refusals included, rather than assumed because they are
      // the safe kind.
      //
      // **What a v14 refusal leaves behind on this path is v13, not v11.**
      // `PostgresMigrations.run` commits each version in its own transaction,
      // so v12 and v13 have landed by the time v14 refuses and rolls back.
      // That is still a consistent server — v13 is schema major 2, the same
      // major a v11 client speaks — and the refusal tests below assert exactly
      // that state rather than "byte-identical to the seed".

      // The five references into `Tags` that v14 widened from `(tag_id)` to
      // `(tag_id, project_id)`. Written out to mirror `schemaV14Statements`'
      // own list statement for statement, rather than derived from
      // `foreignKeys`: this is the inverse of the migration *as written*, and
      // the oracle test below is what checks that against the bootstrap.
      const widened = [
        Tables.triangulationSessions,
        Tables.observations,
        Tables.tagVersions,
        Tables.estimatedPositions,
        Tables.actualTagLocations,
      ];

      /// The eleven columns v12 added, by table, in the order
      /// `schemaV12Statements` adds them.
      const v12Columns = {
        Tables.tags: [
          'pulse_mode_1_name',
          'pulse_mode_2_name',
          'pulse_mode_2_rate_bpm',
          'pulse_mode_3_name',
          'pulse_mode_3_rate_bpm',
        ],
        Tables.tagVersions: [
          'pulse_mode_1_name',
          'pulse_mode_2_name',
          'pulse_mode_2_rate_bpm',
          'pulse_mode_3_name',
          'pulse_mode_3_rate_bpm',
        ],
        Tables.observations: ['pulse_mode'],
      };

      /// The v11 shape, reconstructed from a current bootstrap by undoing v14,
      /// then v13, then v12 (v15 has no statements). Read beside each
      /// migration: every step here is one of its steps run backwards, in
      /// reverse order.
      ///
      /// `Project_Tags` is the one table here that is hand-written whole. Its
      /// column set is the pre-11.219 `TableSpec` (project_id, tag_id, status,
      /// the six sync columns) plus `serverOnlyColumns`, keyed
      /// `(project_id, tag_id)`, with the two foreign keys and two indexes the
      /// v1 bootstrap gave it. v14 drops it, so the oracle cannot check it —
      /// which is acceptable, because the migration reads exactly two of its
      /// columns (`tag_id`, `project_id`) and both are asserted by every test
      /// in this group.
      List<String> reconstructV11Statements() => [
        // Undo v20 (task 11.331): the project's time zone. `Deployments`'
        // own `time_zone` goes with the table in the v17 undo below.
        'ALTER TABLE ${quoted(Tables.projects)} DROP COLUMN time_zone',
        // Undo v18 (task 11.56): the two provenance columns on `Projects`.
        // Its backfill wrote each project's lineage as its own id; dropping
        // the column undoes that, and the seeds below carry neither.
        'ALTER TABLE ${quoted(Tables.projects)} DROP COLUMN copied_at',
        'ALTER TABLE ${quoted(Tables.projects)} DROP COLUMN lineage_id',
        // Undo v17 (task 11.243), in reverse: the dated link goes, and the
        // four columns it took off `Tags` come back. **The three dates come
        // back `NOT NULL`-or-nullable exactly as v11 had them**, which is
        // free here because the table is empty at reconstruction time.
        //
        // `individual_id` and its index and foreign key are re-added only so
        // that the v16 undo below can drop them again, unchanged — the two
        // steps cancel, and keeping them verbatim is what makes "every step
        // here is one of its steps run backwards" readable rather than a
        // thing a reader has to re-derive.
        'DROP TABLE ${quoted(Tables.deployments)} CASCADE',
        'ALTER TABLE ${quoted(Tables.tags)} '
            'ADD COLUMN date_put_on TEXT NOT NULL DEFAULT \'\'',
        'ALTER TABLE ${quoted(Tables.tags)} '
            'ALTER COLUMN date_put_on DROP DEFAULT',
        'ALTER TABLE ${quoted(Tables.tags)} ADD COLUMN date_removed TEXT',
        'ALTER TABLE ${quoted(Tables.tags)} ADD COLUMN capture_date TEXT',
        'ALTER TABLE ${quoted(Tables.tags)} ADD COLUMN individual_id TEXT',
        alterAddForeignKey((
          Tables.tags,
          const ['individual_id', 'project_id'],
          Tables.individuals,
          const ['individual_id', 'project_id'],
        )),
        'CREATE INDEX ${quoted('idx_tags_individual')} '
            'ON ${quoted(Tables.tags)} (individual_id)',
        // Undo v16 (task 11.240), in reverse: the by-animal index, the
        // reference into `Individuals`, the column, the relaxed NOT NULL,
        // then the table. Its backfill wrote `Tags.individual_id` and nulled
        // `Tags.color_hex`; the column drop undoes the first, and the seeds
        // below write their own colours, so nothing of v16 survives into the
        // reconstructed v11.
        'DROP INDEX ${quoted('idx_tags_individual')}',
        'ALTER TABLE ${quoted(Tables.tags)} DROP CONSTRAINT '
            '${quoted(foreignKeyName((Tables.tags, ['individual_id'], Tables.individuals, ['individual_id'])))}',
        'ALTER TABLE ${quoted(Tables.tags)} DROP COLUMN individual_id',
        'ALTER TABLE ${quoted(Tables.tags)} ALTER COLUMN color_hex SET NOT NULL',
        'DROP TABLE ${quoted(Tables.individuals)} CASCADE',
        // Undo v14, step 7: the widened references and the two
        // project/sequence indexes.
        for (final table in widened)
          'ALTER TABLE ${quoted(table)} DROP CONSTRAINT '
              '${quoted(foreignKeyName((table, ['tag_id'], Tables.tags, ['tag_id'])))}',
        'DROP INDEX ${quoted('idx_${Tables.tags}_project_seq'.toLowerCase())}',
        'DROP INDEX '
            '${quoted('idx_${Tables.tagVersions}_project_seq'.toLowerCase())}',
        'CREATE INDEX ${quoted('idx_${Tables.tags}_seq'.toLowerCase())} '
            'ON ${quoted(Tables.tags)} (server_seq)',
        'CREATE INDEX ${quoted('idx_${Tables.tagVersions}_seq'.toLowerCase())} '
            'ON ${quoted(Tables.tagVersions)} (server_seq)',
        // Undo v14, steps 5 and 2: the composite keys and the four added
        // columns.
        'ALTER TABLE ${quoted(Tables.tags)} '
            'DROP CONSTRAINT ${quoted('${Tables.tags}_pkey')}',
        'ALTER TABLE ${quoted(Tables.tags)} DROP COLUMN project_id',
        'ALTER TABLE ${quoted(Tables.tags)} DROP COLUMN lineage_id',
        'ALTER TABLE ${quoted(Tables.tags)} DROP COLUMN copied_at',
        'ALTER TABLE ${quoted(Tables.tags)} ADD PRIMARY KEY (tag_id)',
        'ALTER TABLE ${quoted(Tables.tagVersions)} '
            'DROP CONSTRAINT ${quoted('${Tables.tagVersions}_pkey')}',
        'ALTER TABLE ${quoted(Tables.tagVersions)} DROP COLUMN project_id',
        'ALTER TABLE ${quoted(Tables.tagVersions)} '
            'ADD PRIMARY KEY (tag_version_id)',
        // Undo v14, step 4: `Project_Tags`, as the v1 bootstrap built it.
        'CREATE TABLE ${quoted(Tables.projectTags)} ('
            'project_id TEXT NOT NULL, '
            'tag_id TEXT NOT NULL, '
            'status TEXT NOT NULL, '
            'created_at TEXT NOT NULL, '
            'updated_at TEXT NOT NULL, '
            'deleted_at TEXT, '
            'revision BIGINT NOT NULL, '
            'last_modified_by TEXT, '
            'origin_device_id TEXT, '
            '${serverOnlyColumns.join(', ')}, '
            'PRIMARY KEY (project_id, tag_id))',
        alterAddForeignKey((
          Tables.projectTags,
          const ['project_id'],
          Tables.projects,
          const ['project_id'],
        )),
        alterAddForeignKey((
          Tables.projectTags,
          const ['tag_id'],
          Tables.tags,
          const ['tag_id'],
        )),
        'CREATE INDEX '
            '${quoted('idx_${Tables.projectTags}_project_seq'.toLowerCase())} '
            'ON ${quoted(Tables.projectTags)} (project_id, server_seq)',
        'CREATE INDEX ${quoted('idx_${Tables.projectTags}_skew'.toLowerCase())} '
            'ON ${quoted(Tables.projectTags)} (clock_skew_flag) '
            'WHERE clock_skew_flag IS NOT NULL',
        // Undo v14, step 1: the single-column references back on.
        for (final table in widened)
          alterAddForeignKey((
            table,
            const ['tag_id'],
            Tables.tags,
            const ['tag_id'],
          )),
        // Undo v13: the one column it added.
        'ALTER TABLE ${quoted(Tables.observations)} DROP COLUMN signal_irregular',
        // Undo v12: its eleven columns. Its two `UPDATE`s wrote into two of
        // them, so dropping the columns undoes those too.
        for (final MapEntry(key: table, value: columns) in v12Columns.entries)
          for (final column in columns)
            'ALTER TABLE ${quoted(table)} DROP COLUMN $column',
        // The bootstrap records only the target version, so after deleting it
        // the ledger is empty and `PostgresMigrations.run` would look for a v1
        // migration that does not exist. A real v11 server holds a row for
        // every version it has passed through; `run` reads only the highest,
        // so one row is the honest minimum.
        'DELETE FROM schema_migrations WHERE version > 11',
        'INSERT INTO schema_migrations (version) VALUES (11)',
      ];

      /// Every line `PostgresMigrations.run` wrote during the last [upgrade].
      /// The deletion in v14's step 0b is asserted here, because a deletion
      /// inside a migration that nobody can see in the log is the defect the
      /// log line exists to prevent.
      final logged = <String>[];

      setUp(() async {
        logged.clear();
        for (final statement in reconstructV11Statements()) {
          await connection.execute(statement);
        }
      });

      /// One user, two projects, one open membership in each. Every tag and
      /// record below is added to one of the two projects explicitly, so a
      /// scoping bug that put everything in the first project is visible.
      Future<void> seedV11Base() async {
        await connection.execute(
          'INSERT INTO ${quoted(Tables.users)} '
          '(user_id, first_name, last_name, email, created_at, updated_at, '
          'revision) '
          r"VALUES ('user-1', 'Sam', 'Ranger', 'sam@example.com', $1, $1, 0)",
          parameters: [at],
        );
        for (final (project, name) in [
          ('proj-1', 'Peaks'),
          ('proj-2', 'Canyon'),
        ]) {
          await connection.execute(
            'INSERT INTO ${quoted(Tables.projects)} '
            '(project_id, project_name, owner_user_id, creation_date, datum, '
            'created_at, updated_at, revision, coordinate_format, '
            'triangulation_window_minutes) '
            r"VALUES ($2, $3, 'user-1', $1, 'WGS84', $1, $1, 0, 'dd', 15)",
            parameters: [at, project, name],
          );
          await connection.execute(
            'INSERT INTO ${quoted(Tables.projectMemberships)} '
            '(membership_id, project_id, user_id, join_date, end_date, role, '
            'created_at, updated_at, revision, last_modified_by) '
            r"VALUES ($2, $3, 'user-1', $1, NULL, 'owner', $1, $1, 0, 'user-1')",
            parameters: [at, 'mem-$project', project],
          );
        }
      }

      /// A v11 `Tags` row — no `project_id`, no `lineage_id`, no pulse-mode
      /// columns — linked into each of [linkedTo] through `Project_Tags`,
      /// which is the only place a v11 database records which project holds
      /// a tag.
      Future<void> seedV11Tag(
        String tagId, {
        required List<String> linkedTo,
        String? name,
      }) async {
        await connection.execute(
          'INSERT INTO ${quoted(Tables.tags)} '
          '(tag_id, frequency_mhz, tag_name, date_put_on, status, color_hex, '
          'pulse_rate, created_at, updated_at, revision) '
          r"VALUES ($2, 150.125, $3, $1, 'active', '#FF0000', 60.0, $1, $1, 2)",
          parameters: [at, tagId, name ?? 'Goshawk $tagId'],
        );
        for (final project in linkedTo) {
          await connection.execute(
            'INSERT INTO ${quoted(Tables.projectTags)} '
            '(project_id, tag_id, status, created_at, updated_at, revision, '
            'last_modified_by) '
            r"VALUES ($2, $3, 'active', $1, $1, 0, 'user-1')",
            parameters: [at, project, tagId],
          );
        }
      }

      /// A v11 `Tag_Versions` row for [tagId]. Split out of
      /// [seedV11RecordsNaming] because it is the one reference into `Tags`
      /// that carries no `project_id` at v11 — and therefore the one the
      /// census query task 11.222 gave Michael does not read. A tag linked to
      /// no project with only this naming it is the case v14's step 0 has to
      /// find on its own.
      Future<void> seedV11Version(String tagId) async {
        await connection.execute(
          'INSERT INTO ${quoted(Tables.tagVersions)} '
          '(tag_version_id, tag_id, effective_from, frequency_mhz, tag_name, '
          'pulse_rate, created_at, updated_at, revision) '
          r"VALUES ('ver-' || $2::text, $2, $1, 150.125, 'Goshawk ' || $2::text, "
          r'60.0, $1, $1, 0)',
          parameters: [at, tagId],
        );
      }

      /// Every kind of record that names a tag, all in [project]: a version,
      /// a session, a bearing in that session naming that version, an
      /// exclusion of that bearing, an estimate built from it, a truth point,
      /// and a non-detection listening for the tag. Ids carry the tag id so
      /// two tags' records never collide.
      Future<void> seedV11RecordsNaming(
        String tagId, {
        required String project,
      }) async {
        final p = [at, tagId, project];
        await seedV11Version(tagId);
        await connection.execute(
          'INSERT INTO ${quoted(Tables.triangulationSessions)} '
          '(session_id, project_id, tag_id, started_at_local, started_at_utc, '
          'started_at_offset, label, created_at, updated_at, revision) '
          r"VALUES ('ses-' || $2::text, $3, $2, $1, $1, '-07:00', 'morning', "
          r'$1, $1, 1)',
          parameters: p,
        );
        await connection.execute(
          'INSERT INTO ${quoted(Tables.observations)} '
          '(observation_id, project_id, user_id, tag_id, session_id, '
          'tag_version_id, timestamp_local, timestamp_utc, timezone_offset, '
          'latitude, longitude, position_source, elevation, altitude_agl, '
          'observation_type, magnetic_bearing, signal_type, signal_strength, '
          'notes, created_at, updated_at, revision) '
          r"VALUES ('obs-' || $2::text, $3, 'user-1', $2, 'ses-' || $2::text, "
          r"'ver-' || $2::text, "
          r"$1, $1, '-07:00', 35.19, -111.62, 'gps_fix', 2103.0, 0.0, "
          r"'directional', 145.0, 'pulse', 'strong', 'steady', $1, $1, 3)",
          parameters: p,
        );
        await connection.execute(
          'INSERT INTO ${quoted(Tables.observationExclusions)} '
          '(exclusion_id, project_id, observation_id, user_id, kind, reason, '
          'created_at, updated_at, revision) '
          r"VALUES ('excl-' || $2::text, $3, 'obs-' || $2::text, 'user-1', 'exclude', "
          r"'bounce', $1, $1, 0)",
          parameters: p,
        );
        await connection.execute(
          'INSERT INTO ${quoted(Tables.estimatedPositions)} '
          '(position_id, project_id, tag_id, timestamp_local, timestamp_utc, '
          'timezone_offset, latitude, longitude, semi_major_axis, '
          'semi_minor_axis, rotation_angle, method, observation_ids_used, '
          'created_at, updated_at, revision) '
          r"VALUES ('est-' || $2::text, $3, $2, $1, $1, '-07:00', 35.20, -111.60, "
          r"120.0, 80.0, 30.0, 'mle', 'obs-' || $2::text, $1, $1, 0)",
          parameters: p,
        );
        await connection.execute(
          'INSERT INTO ${quoted(Tables.actualTagLocations)} '
          '(location_id, project_id, tag_id, timestamp_local, timestamp_utc, '
          'timezone_offset, latitude, longitude, uncertainty_radius, '
          'found_kind, tag_version_id, user_id, position_source, '
          'created_at, updated_at, revision) '
          r"VALUES ('truth-' || $2::text, $3, $2, $1, $1, '-07:00', 35.21, -111.61, "
          r"5.0, 'both', 'ver-' || $2::text, 'user-1', 'gps_fix', $1, $1, 0)",
          parameters: p,
        );
        await connection.execute(
          'INSERT INTO ${quoted(Tables.nonDetections)} '
          '(non_detection_id, project_id, user_id, timestamp_local, '
          'timestamp_utc, timezone_offset, latitude, longitude, '
          'position_source, elevation, altitude_agl, tag_ids_listened_for, '
          'created_at, updated_at, revision) '
          r"VALUES ('nd-' || $2::text, $3, 'user-1', $1, $1, '-07:00', 35.18, "
          r"-111.63, 'gps_fix', 2100.0, 0.0, $2, $1, $1, 0)",
          parameters: p,
        );
      }

      /// **The beta server's census, 2026-09-11, as a fixture.** Five collars:
      /// four linked to exactly one project, none linked to two or more, one
      /// linked to none, and no row anywhere naming a collar in a project it
      /// is not linked to. Built from those numbers rather than from a round
      /// five, so the test that uses it is a claim about that database. The
      /// census did not say how the four are split between projects or which
      /// carry records; two per project with a full set of records each is
      /// the harder reading, and the orphan has nothing naming it because the
      /// census's fourth line was empty and — see [seedV11Version] — the one
      /// table the census does not read is asserted separately below.
      Future<void> seedBetaServerCensus() async {
        await seedV11Base();
        for (final (tag, project) in [
          ('tag-1', 'proj-1'),
          ('tag-2', 'proj-1'),
          ('tag-3', 'proj-2'),
          ('tag-4', 'proj-2'),
        ]) {
          await seedV11Tag(tag, linkedTo: [project]);
          await seedV11RecordsNaming(tag, project: project);
        }
        await seedV11Tag('tag-orphan', linkedTo: []);
      }

      /// Every table a v11 database holds that this group seeds, plus the
      /// migration ledger. `Project_Tags` is present before v14 and absent
      /// after; the tests say which they expect.
      const seededTables = [
        Tables.users,
        Tables.projects,
        Tables.projectMemberships,
        Tables.tags,
        Tables.projectTags,
        Tables.tagVersions,
        Tables.triangulationSessions,
        Tables.observations,
        Tables.observationExclusions,
        Tables.estimatedPositions,
        Tables.actualTagLocations,
        Tables.nonDetections,
        'schema_migrations',
      ];

      /// The first primary-key column is the row's own id on every shared
      /// table, and it is unique in every seed above, so ordering by it alone
      /// works on both the v11 shape (where `Tags` has no `project_id`) and
      /// the v15 one.
      String orderColumn(String table) => switch (table) {
        'schema_migrations' => 'version',
        Tables.projectTags => 'project_id, tag_id',
        _ => tableSpecsByName[table]!.primaryKeyColumns.first.name,
      };

      Future<Map<String, List<Map<String, Object?>>>> snapshotSeededTables({
        required bool withProjectTags,
      }) async {
        final result = <String, List<Map<String, Object?>>>{};
        for (final table in seededTables) {
          if (table == Tables.projectTags && !withProjectTags) continue;
          final rows = await connection.execute(
            'SELECT * FROM ${quoted(table)} ORDER BY ${orderColumn(table)}',
          );
          result[table] = [for (final row in rows) row.toColumnMap()];
        }
        return result;
      }

      /// [after] restricted to the columns [before] had, so the two can be
      /// compared byte for byte on everything the migrations did not add.
      /// `Project_Tags` and the ledger are left out: one is dropped by v14 and
      /// the other is what moved.
      Map<String, List<Map<String, Object?>>> carriedColumns(
        Map<String, List<Map<String, Object?>>> after,
        Map<String, List<Map<String, Object?>>> before,
      ) => {
        for (final entry in after.entries)
          if (entry.key != 'schema_migrations' &&
              entry.key != Tables.projectTags)
            entry.key: [
              for (final row in entry.value)
                Map<String, Object?>.of(row)..removeWhere(
                  (column, _) => !before[entry.key]!.first.containsKey(column),
                ),
            ],
      };

      /// What v12 and v13 are expected to have done to every row that was
      /// there when they ran — the expectation written down, then checked.
      /// v12 adds eleven nullable columns and writes the two default mode
      /// *names* into every `Tags` and `Tag_Versions` row (`Normal`,
      /// `Mortality`) and **no rates** — a mortality rate is a measurement
      /// nobody took. v13 adds `signal_irregular`, nullable, with no default
      /// and no `UPDATE` — a 0 would say every observer listened and heard
      /// nothing wrong.
      void expectV12AndV13Additions(
        Map<String, List<Map<String, Object?>>> after,
      ) {
        for (final table in [Tables.tags, Tables.tagVersions]) {
          for (final row in after[table]!) {
            expect(
              row['pulse_mode_1_name'],
              defaultPulseModeNames[0],
              reason: '$table.pulse_mode_1_name after v12',
            );
            expect(
              row['pulse_mode_2_name'],
              defaultPulseModeNames[1],
              reason: '$table.pulse_mode_2_name after v12',
            );
            expect(
              row['pulse_mode_2_rate_bpm'],
              isNull,
              reason: '$table.pulse_mode_2_rate_bpm: v12 writes no rate',
            );
            expect(row['pulse_mode_3_name'], isNull);
            expect(row['pulse_mode_3_rate_bpm'], isNull);
          }
        }
        for (final row in after[Tables.observations]!) {
          expect(row.containsKey('pulse_mode'), isTrue);
          expect(row['pulse_mode'], isNull, reason: 'v12 backfills no mode');
          expect(row.containsKey('signal_irregular'), isTrue);
          expect(
            row['signal_irregular'],
            isNull,
            reason: 'v13 must not claim anybody heard nothing wrong',
          );
        }
      }

      /// Runs the real upgrade path — `PostgresMigrations.run`, which wraps
      /// each version in its own transaction — rather than executing the
      /// statements by hand the way the older groups do. The refusal tests
      /// depend on that transaction: "v14 changed nothing" is a claim about
      /// the rollback, and only the real path has one. Everything the run
      /// logs is kept in [logged].
      ///
      /// **Stops at v16, one short of the current version** (task 11.243).
      /// Schema v17 empties every table the versions above populate, on
      /// purpose (`ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §9) — so a run to
      /// `targetVersion` could assert only the wipe, and what v14 and v16 do
      /// to a *populated* database would stop being checked at all. That is
      /// what this group exists for. The wipe has a group of its own below.
      Future<void> upgrade() => PostgresMigrations.run(
            connection,
            log: logged.add,
            upTo: _lastVersionBeforeTheWipe,
          );

      /// The whole path, v17 included — for the oracle below, which compares
      /// an upgraded catalog against a fresh bootstrap and therefore has to
      /// reach the same version the bootstrap builds.
      Future<void> upgradeFully() =>
          PostgresMigrations.run(connection, log: logged.add);

      Future<List<int>> appliedVersions() async {
        final rows = await connection.execute(
          'SELECT version FROM schema_migrations ORDER BY version',
        );
        return [for (final row in rows) row.first! as int];
      }

      Future<bool> tagsHasProjectColumn() async {
        final rows = await connection.execute(
          'SELECT count(*) FROM information_schema.columns '
          r"WHERE table_schema = $1 AND table_name = $2 "
          "AND column_name = 'project_id'",
          parameters: [testSchema, Tables.tags],
        );
        return (rows.single.first! as int) == 1;
      }

      /// The migration's whole claim is that these still resolve afterwards.
      /// Asserted by query rather than trusted to the constraints, because the
      /// constraints are deferred and a row that dangles is exactly what this
      /// file exists to notice.
      Future<void> expectEveryForeignKeyResolves() async {
        // **Only the tables this database actually has** (task 11.243). Most
        // of this group stops at v16, one version before the current one, so
        // `Deployments` is not there yet — and a check that threw
        // *"relation does not exist"* would be reporting the group's own
        // stopping point as a dangling reference. Derived from the catalog
        // rather than from a list of exceptions, so the next table added
        // needs no edit here.
        final existing = {
          for (final row in await connection.execute(
            'SELECT table_name FROM information_schema.tables '
            r'WHERE table_schema = $1',
            parameters: [testSchema],
          ))
            row.first! as String,
        };
        for (final (table, columns, refTable, refColumns) in foreignKeys) {
          if (!existing.contains(table) || !existing.contains(refTable)) {
            continue;
          }
          final notNull = columns.map((c) => 'c.$c IS NOT NULL').join(' AND ');
          final match = [
            for (var i = 0; i < columns.length; i++)
              'p.${refColumns[i]} = c.${columns[i]}',
          ].join(' AND ');
          final rows = await connection.execute(
            'SELECT count(*) FROM ${quoted(table)} c WHERE $notNull AND '
            'NOT EXISTS (SELECT 1 FROM ${quoted(refTable)} p WHERE $match)',
          );
          expect(
            rows.single.first,
            0,
            reason:
                '$table.${columns.join('+')} has rows that resolve to no '
                '$refTable row after the upgrade',
          );
        }
      }

      /// The whole path went through: the ledger runs 11 to 15, each version
      /// said so, and v14's deletion line is present with [deletedTags] —
      /// which is "0" and no ids when nothing was there to delete.
      Future<void> expectUpgradedAndLogged({
        required List<String> deletedTags,
      }) async {
        expect(await appliedVersions(), [11, 12, 13, 14, 15, 16]);
        expect(
          logged,
          containsAllInOrder([
            'schema v12: applied',
            'schema v13: applied',
            'schema v14: deleted ${deletedTags.length} tag row(s) linked to no '
                'project and named by nothing'
                '${deletedTags.isEmpty ? '' : ': ${deletedTags.join(', ')}'}',
            'schema v14: applied',
            'schema v15: applied',
            'schema v16: applied',
          ]),
        );
        // v16's census names its counts (task 11.240); a migration that
        // creates a row per existing row and prints nothing cannot be told
        // from one that created none.
        expect(
          logged,
          contains(
            matches(
              RegExp(
                r'^schema v16: (\d+) tag row\(s\) found; \1 individual\(s\) '
                r'created, one per tag, none merged by name; \1 tag\(s\) now '
                r'name their animal$',
              ),
            ),
          ),
        );
      }

      /// What v16 (task 11.240) does to every tag that was there when it ran:
      /// one `Individuals` row keyed by the tag's id, wearing the tag's name
      /// and colour, its lineage its own id, tombstoned iff the tag is; the
      /// tag names it and its own colour is nulled. Two tags with the same
      /// name stay two animals. And every backfilled row has a `server_seq`,
      /// because a row with none is never delivered by pull.
      Future<void> expectV16Backfill(
        Map<String, List<Map<String, Object?>>> after,
        Map<String, List<Map<String, Object?>>> before,
      ) async {
        final individuals = await connection.execute(
          'SELECT * FROM ${quoted(Tables.individuals)} ORDER BY individual_id',
        );
        final byId = {
          for (final row in individuals)
            row.toColumnMap()['individual_id']! as String: row.toColumnMap(),
        };
        final beforeById = {
          for (final tag in before[Tables.tags]!) tag['tag_id']! as String: tag,
        };
        expect(byId.keys, after[Tables.tags]!.map((t) => t['tag_id']));
        for (final tag in after[Tables.tags]!) {
          final id = tag['tag_id']! as String;
          final animal = byId[id]!;
          final seed = beforeById[id]!;
          expect(tag['individual_id'], id);
          expect(tag['color_hex'], isNull, reason: 'retired column emptied');
          expect(animal['project_id'], tag['project_id']);
          expect(animal['name'], seed['tag_name']);
          expect(animal['color_hex'], seed['color_hex']);
          expect(animal['lineage_id'], id);
          expect(animal['copied_at'], isNull);
          expect(animal['deleted_at'], seed['deleted_at']);
          expect(animal['status'],
              seed['status'] == 'active' ? 'alive' : 'unknown');
          expect(animal['revision'], 0);
          expect(animal['server_seq'], isNotNull,
              reason: 'a row with no server_seq is never delivered by pull');
        }
        final counter = await connection.execute(
          'SELECT next_value FROM sync_seq_counter',
        );
        for (final animal in byId.values) {
          expect(
            animal['server_seq']! as int,
            lessThanOrEqualTo(counter.first.first! as int),
            reason: 'the block was reserved from the counter, not invented',
          );
        }
      }

      /// [before] as v16 leaves the tag rows: colour moved to the animal, so
      /// the carried-column comparison expects null where the seed had one.
      Map<String, List<Map<String, Object?>>> withTagColoursMoved(
        Map<String, List<Map<String, Object?>>> before,
      ) => {
        for (final entry in before.entries)
          entry.key: entry.key == Tables.tags
              ? [
                  for (final tag in entry.value)
                    Map<String, Object?>.of(tag)..['color_hex'] = null,
                ]
              : entry.value,
      };

      /// v14 refused with a message naming every string in [naming]; v12 and
      /// v13 had already landed, so the database is v13-shaped — `Tags` has no
      /// `project_id`, `Project_Tags` is still there, the ledger stops at 13 —
      /// with every row byte-identical to the seed on the columns v11 had, and
      /// v12's additions holding exactly what v12 writes.
      Future<void> expectRefusedAtV13({
        required Map<String, List<Map<String, Object?>>> before,
        required List<String> naming,
        String refusal = 'schema v14 refused',
      }) async {
        await expectLater(
          upgrade(),
          throwsA(
            isA<ServerException>()
                .having((e) => e.code, 'SQLSTATE', 'P0001')
                .having(
                  (e) => e.message,
                  'message',
                  allOf([
                    contains(refusal),
                    for (final text in naming) contains(text),
                  ]),
                ),
          ),
        );
        expect(await tagsHasProjectColumn(), isFalse);
        expect(await appliedVersions(), [11, 12, 13]);
        final after = await snapshotSeededTables(withProjectTags: true);
        expect(after[Tables.projectTags], before[Tables.projectTags]);
        expect(
          carriedColumns(after, before),
          Map.of(before)
            ..remove(Tables.projectTags)
            ..remove('schema_migrations'),
        );
        expectV12AndV13Additions(after);
        expect(
          logged,
          isNot(contains(startsWith('schema v14:'))),
          reason: 'a refused v14 must log nothing, least of all a deletion',
        );
      }

      test('populated: every row survives, every value is unchanged except the '
          'keys the migration exists to move, v12 and v13 add exactly what they '
          'say, and every foreign key resolves', () async {
        await seedV11Base();
        await seedV11Tag('tag-1', linkedTo: ['proj-1']);
        await seedV11RecordsNaming('tag-1', project: 'proj-1');
        await seedV11Tag('tag-2', linkedTo: ['proj-2']);
        await seedV11RecordsNaming('tag-2', project: 'proj-2');
        final before = await snapshotSeededTables(withProjectTags: true);

        await upgrade();

        final after = await snapshotSeededTables(withProjectTags: false);
        await expectUpgradedAndLogged(deletedTags: []);

        // Row counts first — a table silently emptied is the failure this
        // file is for, and it must be reported as a count rather than as
        // one mismatched map.
        for (final table in after.keys) {
          if (table == 'schema_migrations') continue;
          expect(
            after[table]!.length,
            before[table]!.length,
            reason: '$table changed row count across the upgrade',
          );
        }

        // The moved keys: `Tags` gains `project_id` (the one linked
        // project), `lineage_id` (its own id) and `copied_at` (NULL — nobody
        // copied it); `Tag_Versions` gains its tag's `project_id`.
        final linkedProject = {
          for (final link in before[Tables.projectTags]!)
            link['tag_id']! as String: link['project_id'],
        };
        for (final tag in after[Tables.tags]!) {
          expect(tag['project_id'], linkedProject[tag['tag_id']]);
          expect(tag['lineage_id'], tag['tag_id']);
          expect(tag['copied_at'], isNull);
        }
        for (final version in after[Tables.tagVersions]!) {
          expect(version['project_id'], linkedProject[version['tag_id']]);
        }

        // v12 and v13's additions, v16's backfill, then everything else
        // byte for byte on the columns that existed at v11 — except a tag's
        // colour, which v16 moved to its animal.
        expectV12AndV13Additions(after);
        await expectV16Backfill(after, before);
        expect(
          carriedColumns(after, before),
          withTagColoursMoved(before)
            ..remove(Tables.projectTags)
            ..remove('schema_migrations'),
        );

        await expectEveryForeignKeyResolves();
      });

      test('populated: two tags with the same name stay two animals — the '
          'migration never guesses who is who', () async {
        await seedV11Base();
        await seedV11Tag('marie-2025', linkedTo: ['proj-1'], name: 'Marie');
        await seedV11Tag('marie-2026', linkedTo: ['proj-1'], name: 'Marie');
        await upgrade();
        final maries = await connection.execute(
          'SELECT individual_id, lineage_id FROM ${quoted(Tables.individuals)} '
          "WHERE name = 'Marie' ORDER BY individual_id",
        );
        expect(
          [for (final row in maries) row.first],
          ['marie-2025', 'marie-2026'],
        );
        expect(
          {for (final row in maries) row[1]},
          hasLength(2),
          reason: 'and not one animal by lineage either',
        );
      });

      test('empty: a project with no tags upgrades, its rows are untouched, '
          'and the deletion line says zero', () async {
        // What a new beta tester's device looks like.
        await seedV11Base();
        final before = await snapshotSeededTables(withProjectTags: true);

        await upgrade();

        await expectUpgradedAndLogged(deletedTags: []);
        final after = await snapshotSeededTables(withProjectTags: false);
        expect(
          Map.of(after)..remove('schema_migrations'),
          Map.of(before)
            ..remove(Tables.projectTags)
            ..remove('schema_migrations'),
        );
        expect(
          (await connection.execute(
            'SELECT count(*) FROM ${quoted(Tables.individuals)}',
          )).first.first,
          0,
          reason: 'no tags, so v16 names no animals',
        );
        await expectEveryForeignKeyResolves();
      });

      test(
        "the beta server's census: the collar linked to no project is deleted, "
        'counted and named, and the four linked to one project each come '
        'through untouched',
        () async {
          await seedBetaServerCensus();
          final before = await snapshotSeededTables(withProjectTags: true);
          expect(before[Tables.tags]!.length, 5);

          await upgrade();

          await expectUpgradedAndLogged(deletedTags: ['tag-orphan']);
          final after = await snapshotSeededTables(withProjectTags: false);
          expect(
            [for (final tag in after[Tables.tags]!) tag['tag_id']],
            ['tag-1', 'tag-2', 'tag-3', 'tag-4'],
          );
          // The four, byte for byte on the columns v11 had — and every other
          // table's row count unchanged, because nothing named the orphan.
          final expected = Map.of(before)
            ..remove(Tables.projectTags)
            ..remove('schema_migrations');
          expected[Tables.tags] = [
            for (final tag in withTagColoursMoved(expected)[Tables.tags]!)
              if (tag['tag_id'] != 'tag-orphan') tag,
          ];
          expect(carriedColumns(after, before), expected);
          expectV12AndV13Additions(after);
          await expectV16Backfill(after, before);
          await expectEveryForeignKeyResolves();
        },
      );

      test(
        'refused: a tag linked to two projects aborts v14 by name — that one '
        'is a decision about the record and stays a refusal',
        () async {
          // The local schema permitted this and the app offered it until task
          // 11.218; Michael's phone held two such collars on 2026-09-10.
          await seedV11Base();
          await seedV11Tag('tag-shared', linkedTo: ['proj-1', 'proj-2']);
          await seedV11RecordsNaming('tag-shared', project: 'proj-1');
          await seedV11Tag('tag-1', linkedTo: ['proj-1']);
          final before = await snapshotSeededTables(withProjectTags: true);

          await expectRefusedAtV13(
            before: before,
            naming: ['tag-shared is linked to 2 projects'],
          );
        },
      );

      test('refused: a tag linked to no project but with a version chain is not '
          'deleted, and the message names Tag_Versions — the table the census '
          'query does not read', () async {
        await seedV11Base();
        await seedV11Tag('tag-orphan', linkedTo: []);
        await seedV11Version('tag-orphan');
        await seedV11Tag('tag-1', linkedTo: ['proj-1']);
        final before = await snapshotSeededTables(withProjectTags: true);

        await expectRefusedAtV13(
          before: before,
          naming: [
            'tag-orphan is linked to no project but is still named by '
                '${quoted(Tables.tagVersions)} (1 rows), so it was not deleted',
          ],
        );
      });

      test(
        'refused: a tag linked to no project but named by every kind of record '
        'is not deleted, and the message names each table that names it',
        () async {
          await seedV11Base();
          await seedV11Tag('tag-orphan', linkedTo: []);
          await seedV11RecordsNaming('tag-orphan', project: 'proj-2');
          final before = await snapshotSeededTables(withProjectTags: true);

          await expectRefusedAtV13(
            before: before,
            naming: [
              'tag-orphan is linked to no project but is still named by',
              for (final table in widened) '${quoted(table)} (1 rows)',
              'so it was not deleted',
              // The same rows are also strays — named by a project the tag
              // is not linked to — and that line is kept too, because it says
              // which project.
              'tag-orphan is named by rows in project proj-2',
            ],
          );
        },
      );

      test('refused: a tag linked to one project but named by a bearing in '
          'another aborts v14 by name', () async {
        // Without the refusal, this is the case the foreign-key step would
        // catch by accident, with an error naming a constraint. With it, the
        // message names the tag and the project, before anything moves.
        await seedV11Base();
        await seedV11Tag('tag-stray', linkedTo: ['proj-1']);
        await seedV11RecordsNaming('tag-stray', project: 'proj-2');
        final before = await snapshotSeededTables(withProjectTags: true);

        await expectRefusedAtV13(
          before: before,
          naming: ['tag-stray', 'proj-2'],
        );
      });

      test('every refusal is listed in one message, so the log names every '
          'collar to look at rather than the first', () async {
        await seedV11Base();
        await seedV11Tag('tag-shared', linkedTo: ['proj-1', 'proj-2']);
        await seedV11Tag('tag-orphan', linkedTo: []);
        await seedV11Version('tag-orphan');
        final before = await snapshotSeededTables(withProjectTags: true);

        await expectRefusedAtV13(
          before: before,
          naming: ['tag-shared', 'tag-orphan'],
        );
      });

      test('the derivation of "what names a tag" refuses an empty result rather '
          'than concluding nothing does', () async {
        // A v11 database with no foreign key into `Tags` cannot exist — the
        // v1 bootstrap made five and nothing has dropped one — so a catalog
        // reporting none means the derivation is looking at the wrong thing,
        // and a search that finds nothing must not read as "nothing names
        // this tag". Built by breaking the reconstruction on purpose.
        await seedV11Base();
        await seedV11Tag('tag-orphan', linkedTo: []);
        await seedV11Version('tag-orphan');
        for (final table in widened) {
          await connection.execute(
            'ALTER TABLE ${quoted(table)} DROP CONSTRAINT '
            '${quoted(foreignKeyName((table, ['tag_id'], Tables.tags, ['tag_id'])))}',
          );
        }
        final before = await snapshotSeededTables(withProjectTags: true);

        await expectRefusedAtV13(
          before: before,
          refusal:
              'the catalog reports no foreign key into '
              '${quoted(Tables.tags)}',
          naming: [],
        );
      });

      test(
        'oracle: a reconstructed v11 database, upgraded, has exactly the shape '
        'a fresh bootstrap builds',
        () async {
          // This is what makes the reconstruction above checkable, and it is
          // also the first test that v12, v13 and v14 together build what
          // `schemaStatements()` claims to build in one pass — see the file
          // doc comment.
          //
          // **The full path, v17 included**, unlike every other test in this
          // group: a bootstrap builds the *current* schema, so anything
          // short of it would be comparing two different shapes and calling
          // the difference a failure.
          await upgradeFully();
          await expectMigratedCatalogMatchesBootstrap();
        },
      );

      group('v17 (task 11.243): the wipe, on a populated database', () {
        // **This is the one migration in this file whose success is measured
        // in rows destroyed.** `ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §9:
        // Michael is wiping, every device and the beta server hold
        // development data only, and a data-preserving path would be
        // machinery serving nothing. What has to be true is that it deletes
        // what it says, keeps what it says, and **says so** — a destructive
        // step that does not announce itself is the defect this project has
        // been chasing all week in a new costume.

        Future<int> countOf(String table) async {
          final rows = await connection.execute(
            'SELECT count(*) FROM ${quoted(table)}',
          );
          return rows.single.first! as int;
        }

        test('it empties every table that names a tag, and says how many rows '
            'it destroyed', () async {
          await seedBetaServerCensus();
          await upgrade();
          // **The migration's own list, not a copy of it.** A second list
          // here would go wrong the first time a table was added to one and
          // not the other — and it did, on the first run of this test: it
          // counted eight tables against the migration's nine and reported
          // the difference as a wrong census.
          final before = {
            for (final table in v17EmptiedTables) table: await countOf(table),
          };
          expect(
            before.values.where((n) => n > 0),
            isNotEmpty,
            reason:
                'the premise: if nothing were there, this test would pass '
                'while measuring nothing',
          );

          logged.clear();
          await upgradeFully();

          for (final entry in before.entries) {
            expect(await countOf(entry.key), 0, reason: entry.key);
          }
          // Derived rather than typed: `upgradeFully` runs to whatever
          // `latestSchemaVersion` is, so a list ending at 17 was a test
          // that went red on the next minor for no reason of its own.
          expect(await appliedVersions(), [
            for (var v = 11; v <= latestSchemaVersion; v++) v,
          ]);
          final total = before.values.fold<int>(0, (a, b) => a + b);
          expect(
            logged,
            contains(
              allOf(
                contains('schema v17:'),
                contains('DELETED DATA ON PURPOSE'),
                contains('$total row(s) destroyed'),
              ),
            ),
            reason:
                'the census is the finding — a migration that empties nine '
                'tables and prints nothing cannot be told from one that '
                'emptied none',
          );
        });

        test('the identity tables are untouched — projects, memberships and '
            'sign-in survive the wipe', () async {
          await seedBetaServerCensus();
          await upgrade();
          final before = {
            for (final table in [
              Tables.users,
              Tables.projects,
              Tables.projectMemberships,
            ])
              table: await countOf(table),
          };
          expect(before[Tables.projects], greaterThan(0));

          await upgradeFully();

          for (final entry in before.entries) {
            expect(await countOf(entry.key), entry.value, reason: entry.key);
          }
        });

        test('Tags loses exactly four columns and Deployments arrives',
            () async {
          await seedBetaServerCensus();
          await upgradeFully();

          Future<Set<String>> columnsOf(String table) async {
            final rows = await connection.execute(
              'SELECT column_name FROM information_schema.columns '
              r'WHERE table_schema = $1 AND table_name = $2',
              parameters: [testSchema, table],
            );
            return {for (final row in rows) row.first! as String};
          }

          final tagColumns = await columnsOf(Tables.tags);
          for (final gone in [
            'date_put_on',
            'date_removed',
            'capture_date',
            'individual_id',
          ]) {
            expect(tagColumns, isNot(contains(gone)), reason: gone);
          }
          expect(
            await columnsOf(Tables.deployments),
            containsAll([
              'deployment_id',
              'project_id',
              'tag_id',
              'individual_id',
              'attached_date',
              'removed_date',
            ]),
          );
          // Dropping `individual_id` takes its foreign key with it, and the
          // three new ones are in place. Asserted through the same catalog
          // read the rest of this file uses rather than trusted to the DDL.
          await expectEveryForeignKeyResolves();
        });
      });
    },
  );
}

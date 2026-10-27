import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// The server half of the schema drift guard. The app half
/// (`test/data/schema_matches_shared_spec_test.dart`) checks the live SQLite
/// schema against `tableSpecs`; this checks the generated Postgres DDL against
/// the same declaration, so neither side can drift without a test failing.
void main() {
  group('generated DDL', () {
    test('creates every shared table, quoted so Postgres preserves case', () {
      final statements = schemaStatements();
      for (final spec in tableSpecs) {
        expect(
          statements.any((s) => s.startsWith('CREATE TABLE "${spec.name}"')),
          isTrue,
          reason: 'no CREATE TABLE for ${spec.name}',
        );
      }
    });

    test('mixed-case table names are always quoted', () {
      // Unquoted identifiers get folded to lower case by Postgres, which would
      // silently make `Non_Detections` into `non_detections` and stop matching
      // the shared `Tables` constants.
      //
      // Checked by removing every already-quoted span and then looking for a
      // leftover table name, rather than by asking "does the quoted form
      // appear" — the latter gives false failures because table names are
      // substrings of each other (`Tags` inside `Project_Tags`). Table names
      // are the only mixed-case identifiers in this schema; every column name
      // is lower case, so a capital-letter match in the remainder is
      // unambiguous.
      final quotedSpan = RegExp(r'"[^"]*"');
      for (final statement in schemaStatements()) {
        final unquoted = statement.replaceAll(quotedSpan, '');
        for (final spec in tableSpecs) {
          expect(
            unquoted,
            isNot(contains(spec.name)),
            reason: 'unquoted ${spec.name} in: $statement',
          );
        }
      }
    });

    test('every shared column appears in its table with the mapped type', () {
      for (final spec in tableSpecs) {
        final ddl = schemaStatements().firstWhere(
          (s) => s.startsWith('CREATE TABLE "${spec.name}"'),
        );
        for (final column in spec.columns) {
          expect(
            ddl,
            contains('${column.name} ${postgresType(column.type)}'),
            reason: '${spec.name}.${column.name}',
          );
        }
      }
    });

    test('NOT NULL matches the shared spec, including primary keys', () {
      for (final spec in tableSpecs) {
        final ddl = schemaStatements().firstWhere(
          (s) => s.startsWith('CREATE TABLE "${spec.name}"'),
        );
        for (final column in spec.columns) {
          final line = ddl
              .split('\n')
              .firstWhere((l) => l.trimLeft().startsWith('${column.name} '));
          expect(
            line.contains('NOT NULL'),
            spec.isNotNull(column),
            reason: '${spec.name}.${column.name} nullability',
          );
        }
      }
    });

    test('client timestamp columns stay TEXT, never a Postgres timestamp', () {
      // Converting these would re-render them on the way out, so a row could
      // come back byte-different from how a peer wrote it — breaking
      // MergeResolver's updated_at tie-break and convergence with peers that
      // never saw the server.
      for (final spec in tableSpecs) {
        final ddl = schemaStatements().firstWhere(
          (s) => s.startsWith('CREATE TABLE "${spec.name}"'),
        );
        for (final column in spec.columns) {
          if (column.type != ColumnType.text) continue;
          final line = ddl
              .split('\n')
              .firstWhere((l) => l.trimLeft().startsWith('${column.name} '));
          expect(line, isNot(contains('TIMESTAMP')));
        }
      }
    });

    test('a tag is keyed by its id and its project, in that order', () {
      // **Task 11.219 replaced this test's subject rather than its point.**
      // It read `Project_Tags`, whose `(project_id, tag_id)` pair *was* the
      // identity of a link. That table left the wire with copy-on-add; the
      // composite key it was standing in for is now `Tags` itself, and the
      // order is the other way round on purpose — the id leads and the scope
      // follows, because the leading key column is the one an index can be
      // searched on alone and by-id lookup is the query this schema runs
      // most. See `syncTables`.
      final ddl = schemaStatements().firstWhere(
        (s) => s.startsWith('CREATE TABLE "${Tables.tags}"'),
      );
      expect(ddl, contains('PRIMARY KEY (tag_id, project_id)'));
      expect(
        schemaStatements().where(
          (s) => s.startsWith('CREATE TABLE "${Tables.projectTags}"'),
        ),
        isEmpty,
        reason: 'Project_Tags left the wire in task 11.219',
      );
    });
  });

  group('server-only columns', () {
    test('every table gets server_seq, received_at and clock_skew_flag', () {
      for (final spec in tableSpecs) {
        final ddl = schemaStatements().firstWhere(
          (s) => s.startsWith('CREATE TABLE "${spec.name}"'),
        );
        expect(ddl, contains('server_seq BIGINT'));
        expect(ddl, contains('received_at TIMESTAMPTZ NOT NULL'));
        expect(ddl, contains('clock_skew_flag TEXT'));
      }
    });

    test('server_seq is nullable — Phase 10 invariant 3', () {
      // A device that has never synced must still be able to write rows, so
      // nothing may require this column to be populated.
      for (final spec in tableSpecs) {
        final ddl = schemaStatements().firstWhere(
          (s) => s.startsWith('CREATE TABLE "${spec.name}"'),
        );
        final line = ddl
            .split('\n')
            .firstWhere((l) => l.trimLeft().startsWith('server_seq '));
        expect(line, isNot(contains('NOT NULL')));
      }
    });

    test('server_seq is not part of any primary key', () {
      // It changes on every accepted write — treating it as identity would be
      // a correctness bug, so make sure the schema can't encourage that.
      for (final statement in schemaStatements()) {
        if (!statement.contains('PRIMARY KEY')) continue;
        final pkLine = statement
            .split('\n')
            .firstWhere((l) => l.contains('PRIMARY KEY'), orElse: () => '');
        expect(pkLine, isNot(contains('server_seq')));
      }
    });
  });

  group('sequence counter', () {
    test('is a single-row table constrained to one row', () {
      expect(createSyncSeqCounter, contains('CHECK (only_row)'));
      expect(createSyncSeqCounter, contains('only_row BOOLEAN PRIMARY KEY'));
    });

    test('is seeded, so the first bump has a row to lock', () {
      expect(schemaStatements(), contains(seedSyncSeqCounter));
      expect(
        schemaStatements().indexOf(createSyncSeqCounter),
        lessThan(schemaStatements().indexOf(seedSyncSeqCounter)),
      );
    });

    test('no Postgres SEQUENCE or IDENTITY is used for server_seq', () {
      // A bare sequence hands out values in request order but transactions
      // commit in another order, letting a reader advance its cursor past an
      // uncommitted value and never receive that row. See
      // postgres_schema.dart's createSyncSeqCounter for the full walkthrough.
      for (final statement in schemaStatements()) {
        expect(statement.toUpperCase(), isNot(contains('CREATE SEQUENCE')));
        expect(statement.toUpperCase(), isNot(contains('NEXTVAL')));
        expect(
          statement.toUpperCase(),
          isNot(contains('GENERATED BY DEFAULT AS IDENTITY')),
        );
        expect(statement.toUpperCase(), isNot(contains('BIGSERIAL')));
      }
    });
  });

  group('indexes and constraints', () {
    test(
      'project-scoped tables get a (project_id, server_seq) cursor index',
      () {
        final statements = schemaStatements();
        for (final spec in tableSpecs) {
          if (!spec.columnNames.contains('project_id')) continue;
          expect(
            statements.any(
              (s) => s.contains('ON "${spec.name}" (project_id, server_seq)'),
            ),
            isTrue,
            reason: 'missing cursor index for ${spec.name}',
          );
        }
      },
    );

    test('global tables still get a server_seq index for delta pulls', () {
      final statements = schemaStatements();
      for (final spec in tableSpecs) {
        if (spec.columnNames.contains('project_id')) continue;
        expect(
          statements.any((s) => s.contains('ON "${spec.name}" (server_seq)')),
          isTrue,
          reason: 'missing cursor index for ${spec.name}',
        );
      }
    });

    test(
      'all foreign keys are deferrable, so intra-transaction order is free',
      () {
        for (final fk in foreignKeys) {
          expect(
            alterAddForeignKey(fk),
            contains('DEFERRABLE INITIALLY DEFERRED'),
          );
        }
      },
    );

    test('last_modified_by is never a foreign key, matching the app', () {
      // A merged row may legitimately reference a user row that hasn't synced
      // yet — same reasoning as the app's schema.dart.
      for (final fk in foreignKeys) {
        expect(fk.$2, isNot(contains('last_modified_by')));
      }
    });

    test(
      'task 11.10: a fresh bootstrap gets the one-open-membership index too, '
      'not only an upgrade from an older version',
      () {
        // The bug this test exists to catch: `schemaStatements()` (what a
        // brand-new database runs) is built from `tableSpecs` and
        // `createIndexes()`, neither of which can express a partial unique
        // index — only `serverMigrations` could, and a fresh bootstrap
        // never replays `serverMigrations` (it records
        // `PostgresMigrations.targetVersion` directly and returns). A first
        // version of this schema change added the index only to
        // `serverMigrations[8]`, so every *upgraded* server got it and every
        // brand-new one silently did not.
        final statements = schemaStatements();
        expect(
          statements.any(
            (s) =>
                s.contains('CREATE UNIQUE INDEX') &&
                s.contains('idx_memberships_one_open'),
          ),
          isTrue,
          reason:
              'a fresh bootstrap must include the same standing invariants '
              'an upgrade would apply via serverMigrations',
        );
      },
    );

    test(
      'schemaV8Statements is exactly the one-open-membership partial index',
      () {
        final statements = schemaV8Statements();
        expect(statements, hasLength(1));
        expect(statements.single, contains('CREATE UNIQUE INDEX'));
        expect(statements.single, contains('"Project_Memberships"'));
        expect(
          statements.single,
          contains('WHERE end_date IS NULL AND deleted_at IS NULL'),
        );
      },
    );

    test('serverMigrations is defined for every version through latest', () {
      // Versions 1-5 are deliberately absent (see serverMigrations's own
      // doc comment) — this only asserts the upgrade path exists from the
      // point the server started needing one.
      for (var v = 6; v <= latestSchemaVersion; v++) {
        expect(
          serverMigrations.containsKey(v),
          isTrue,
          reason: 'no upgrade path recorded for schema version $v',
        );
      }
    });

    test('every foreign key names a real shared table and column', () {
      for (final (table, columns, refTable, refColumns) in foreignKeys) {
        final spec = tableSpecsByName[table];
        expect(spec, isNotNull, reason: 'unknown table $table');
        final refSpec = tableSpecsByName[refTable];
        expect(
          refSpec,
          isNotNull,
          reason: 'unknown referenced table $refTable',
        );
        // Both sides became lists in task 10.35, when
        // `Observations.session_id` had to reference a project-scoped key.
        expect(columns, hasLength(refColumns.length),
            reason: '$table: a composite FK must name equally many columns');
        for (final column in columns) {
          expect(spec!.columnNames, contains(column));
        }
        for (final refColumn in refColumns) {
          expect(refSpec!.columnNames, contains(refColumn));
        }
        // And the referenced columns must actually *be* a key, or Postgres
        // rejects the constraint at creation.
        expect(
          refColumns.toSet(),
          anyOf(
            equals(refSpec!.primaryKeyColumns.map((c) => c.name).toSet()),
            // A single-column reference into a table whose key is composite is
            // the exact mistake this guards: it is legal-looking Dart and an
            // error only Postgres sees.
            predicate((_) => false),
          ),
          reason: '$table -> $refTable must reference the full primary key',
        );
      }
    });
  });
}

@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// Integration tests against a **real Postgres**, because the central property
/// of `server_seq` is a claim about Postgres's row-locking and commit
/// visibility that no in-process fake can actually establish.
/// `test/sync/server_seq_test.dart` pins the *contract*; this proves the real
/// driver and the real lock honour it.
///
/// **How to run these.** They are skipped unless a database is reachable, so
/// `dart test` stays green with no infrastructure (Phase 10's invariant 5: the
/// suite must never *need* a server). To actually run them:
///
/// ```bash
/// docker compose up -d postgres          # from the repository root
/// cd server
/// POSTGRES_HOST=localhost POSTGRES_PORT=5432 \
///   POSTGRES_DB=<your POSTGRES_DB> \
///   POSTGRES_USER=<your POSTGRES_USER> \
///   POSTGRES_PASSWORD=<your POSTGRES_PASSWORD> \
///   dart test --tags postgres
/// ```
///
/// Note that `docker-compose.yml` deliberately does **not** publish Postgres to
/// the host (`TriTrack_Security_Model.md` §2.2), so reaching it from `dart test`
/// on the host needs a temporary `docker compose port`-style forward, e.g.
/// `docker compose run --rm -p 5432:5432 postgres`, or running these inside the
/// server container. That friction is the security control working as intended,
/// not a misconfiguration to fix.
void main() {
  late Connection connection;

  /// Every run works in its own schema so a failed run can't poison the next,
  /// and so this never touches a real `public` schema by accident.
  ///
  /// Task 10.89: this used to be `'tritrack_test'`, which is exactly
  /// `.env.example`'s sample `POSTGRES_USER` value. Postgres's `"$user"`
  /// search_path entry resolves to *session_user*, not the schema you meant —
  /// so on any database where `POSTGRES_USER` is literally `tritrack_test`,
  /// every unqualified statement on *every* connection in the suite (not just
  /// this file's) preferred this schema over `public` for the entire window
  /// this schema existed. `server_app_role_test.dart`'s admin connection lost
  /// this race: its unqualified `CREATE TABLE` landed here instead of
  /// `public` because this file's `resetSchema()` happened to have the schema
  /// open at that instant, and the table vanished under `DROP SCHEMA …
  /// CASCADE` on this file's very next reset — reproduced deterministically
  /// by running only these two files together with `-j 2`, and confirmed by
  /// renaming this schema, which cleared the failure on ten consecutive runs.
  /// Suffixed like every sibling file's `testSchema` so it can never again
  /// coincide with a plausible role name.
  const testSchema = 'tritrack_postgres_sync_test';

  setUpAll(() async {
    if (testDatabaseConfig == null) {
      // `setUpAll` can't skip; the per-test `skip:` below handles it. Bail out
      // before attempting a connection so the failure isn't a timeout.
      return;
    }
    connection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.close();
  });

  /// Rebuilds the schema before each test so tests don't order-depend.
  Future<void> resetSchema() async {
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);
  }

  group('migrations', skip: databaseSkipReason, () {
    setUp(resetSchema);

    test('build every shared table from empty', () async {
      final result = await connection.execute(
        'SELECT table_name FROM information_schema.tables '
        r"WHERE table_schema = $1",
        parameters: [testSchema],
      );
      final tables = result.map((row) => row.first as String).toSet();
      for (final spec in tableSpecs) {
        expect(tables, contains(spec.name), reason: 'missing ${spec.name}');
      }
      expect(tables, contains('schema_migrations'));
      expect(tables, contains('sync_seq_counter'));
    });

    test('record the shared schema version', () async {
      final applied = await PostgresMigrations.appliedVersions(connection);
      expect(applied, contains(latestSchemaVersion));
    });

    test('are idempotent — a second run changes nothing', () async {
      await PostgresMigrations.run(connection);
      final applied = await PostgresMigrations.appliedVersions(connection);
      expect(applied, {latestSchemaVersion});
    });

    test(
      'every column in the shared spec exists with the right nullability',
      () async {
        for (final spec in tableSpecs) {
          final result = await connection.execute(
            'SELECT column_name, is_nullable FROM information_schema.columns '
            r'WHERE table_schema = $1 AND table_name = $2',
            parameters: [testSchema, spec.name],
          );
          final nullability = {
            for (final row in result) row[0] as String: row[1] == 'YES',
          };
          for (final column in spec.columns) {
            expect(
              nullability.containsKey(column.name),
              isTrue,
              reason: '${spec.name}.${column.name} missing',
            );
            expect(
              nullability[column.name],
              !spec.isNotNull(column),
              reason: '${spec.name}.${column.name} nullability',
            );
          }
          // Server-only columns, and server_seq specifically must be nullable.
          expect(
            nullability['server_seq'],
            isTrue,
            reason: '${spec.name}.server_seq must be nullable (invariant 3)',
          );
          expect(nullability['received_at'], isFalse);
        }
      },
    );
  });

  group('server_seq', skip: databaseSkipReason, () {
    setUp(resetSchema);

    test('is monotonic under concurrent transactions', () async {
      // The acceptance criterion. Each transaction reserves a block through
      // the locked counter row; the union of all blocks must be a contiguous
      // ascending run with no gaps, repeats, or overlaps.
      const transactions = 12;
      const perTransaction = 3;

      final blocks = await Future.wait([
        for (var i = 0; i < transactions; i++)
          connection.runTx((tx) async {
            final block = await ServerSeq.reserve(
              PostgresSeqCounterStore(tx),
              perTransaction,
            );
            return block;
          }),
      ]);

      final all = blocks.expand((b) => b.values).toList()..sort();
      expect(all, List.generate(transactions * perTransaction, (i) => i + 1));

      // No two blocks overlap.
      for (var i = 0; i < blocks.length; i++) {
        for (var j = i + 1; j < blocks.length; j++) {
          expect(
            blocks[i].values.toSet().intersection(blocks[j].values.toSet()),
            isEmpty,
          );
        }
      }
    });

    test('a committed row is never skipped by a cursor pull', () async {
      // The lost-row scenario stated directly: write rows from concurrent
      // transactions, then walk the cursor. Every row must be delivered
      // exactly once, regardless of commit interleaving.
      await _seedProjectAndUser(connection);

      const writers = 8;
      await Future.wait([
        for (var i = 0; i < writers; i++)
          connection.runTx((tx) async {
            final block = await ServerSeq.reserve(
              PostgresSeqCounterStore(tx),
              1,
            );
            await _insertObservation(tx, id: 'obs-$i', serverSeq: block.first);
          }),
      ]);

      final seen = <String>{};
      var cursor = 0;
      // Page through as a real client would.
      while (true) {
        final page = await connection.execute(
          'SELECT observation_id, server_seq FROM ${quoted(Tables.observations)} '
          r'WHERE server_seq > $1 ORDER BY server_seq LIMIT 3',
          parameters: [cursor],
        );
        if (page.isEmpty) break;
        for (final row in page) {
          expect(
            seen.add(row[0] as String),
            isTrue,
            reason: 'row ${row[0]} delivered twice',
          );
          cursor = row[1] as int;
        }
      }
      expect(
        seen.length,
        writers,
        reason: 'a committed row was never delivered',
      );
    });

    test(
      'an update assigns a fresh, higher value so the row is redelivered',
      () async {
        await _seedProjectAndUser(connection);
        final firstSeq = await connection.runTx((tx) async {
          final block = await ServerSeq.reserve(PostgresSeqCounterStore(tx), 1);
          await _insertObservation(tx, id: 'obs-1', serverSeq: block.first);
          return block.first;
        });

        final secondSeq = await connection.runTx((tx) async {
          final block = await ServerSeq.reserve(PostgresSeqCounterStore(tx), 1);
          await tx.execute(
            'UPDATE ${quoted(Tables.observations)} '
            r'SET revision = 2, server_seq = $1 WHERE observation_id = $2',
            parameters: [block.first, 'obs-1'],
          );
          return block.first;
        });

        expect(secondSeq, greaterThan(firstSeq));
        // A device whose cursor sat at firstSeq must now see the row again.
        final result = await connection.execute(
          'SELECT observation_id FROM ${quoted(Tables.observations)} '
          r'WHERE server_seq > $1',
          parameters: [firstSeq],
        );
        expect(result.map((r) => r.first), contains('obs-1'));
      },
    );
  });

  group('schema behaviour', skip: databaseSkipReason, () {
    setUp(resetSchema);

    test('mixed-case table names survive a round-trip', () async {
      // If any DDL had left an identifier unquoted, Postgres would have folded
      // it to lower case and this insert would fail to find the table.
      await _seedProjectAndUser(connection);
      final result = await connection.execute(
        'SELECT count(*) FROM ${quoted(Tables.nonDetections)}',
      );
      expect(result.first.first, 0);
    });

    test('client timestamps come back byte-identical', () async {
      // The reason these columns are TEXT rather than TIMESTAMPTZ: MergeResolver
      // compares them and peers that never saw the server must agree
      // byte-for-byte.
      await _seedProjectAndUser(connection);
      const updatedAt = '2026-07-30T12:00:00.123Z';
      await connection.runTx((tx) async {
        final block = await ServerSeq.reserve(PostgresSeqCounterStore(tx), 1);
        await _insertObservation(
          tx,
          id: 'obs-ts',
          serverSeq: block.first,
          updatedAt: updatedAt,
        );
      });
      final result = await connection.execute(
        'SELECT updated_at FROM ${quoted(Tables.observations)} '
        r'WHERE observation_id = $1',
        parameters: ['obs-ts'],
      );
      expect(result.first.first, updatedAt);
    });

    test(
      'deferred foreign keys allow child-before-parent within a transaction',
      () async {
        // What deferrable constraints buy: the sync protocol (10.7) doesn't have
        // to sort a pushed batch into FK order for the write to succeed.
        await connection.runTx((tx) async {
          await tx.execute(
            'INSERT INTO ${quoted(Tables.projects)} '
            '(project_id, project_name, owner_user_id, creation_date, datum, '
            'created_at, updated_at, revision, coordinate_format, '
            'triangulation_window_minutes) '
            r"VALUES ($1, 'P', $2, $3, 'WGS84', $3, $3, 0, 'dd', 15)",
            parameters: ['proj-1', 'user-1', '2026-07-01T00:00:00.000Z'],
          );
          // Parent inserted *after* the child that references it.
          await tx.execute(
            'INSERT INTO ${quoted(Tables.users)} '
            '(user_id, first_name, last_name, email, created_at, updated_at, revision) '
            r"VALUES ($1, 'Sam', 'Ranger', 'sam@example.com', $2, $2, 0)",
            parameters: ['user-1', '2026-07-01T00:00:00.000Z'],
          );
        });
        final result = await connection.execute(
          'SELECT count(*) FROM ${quoted(Tables.projects)}',
        );
        expect(result.first.first, 1);
      },
    );

    test('a genuinely dangling foreign key still fails at commit', () async {
      // Deferring the check must not mean skipping it.
      await expectLater(
        connection.runTx((tx) async {
          await tx.execute(
            'INSERT INTO ${quoted(Tables.projects)} '
            '(project_id, project_name, owner_user_id, creation_date, datum, '
            'created_at, updated_at, revision, coordinate_format, '
            'triangulation_window_minutes) '
            r"VALUES ($1, 'P', $2, $3, 'WGS84', $3, $3, 0, 'dd', 15)",
            parameters: ['proj-2', 'nobody', '2026-07-01T00:00:00.000Z'],
          );
        }),
        throwsA(isA<Exception>()),
      );
    });

    test('the sequence counter cannot gain a second row', () async {
      await expectLater(
        connection.execute(
          'INSERT INTO sync_seq_counter (only_row, next_value) VALUES (FALSE, 0)',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
}

Future<void> _seedProjectAndUser(Connection session) async {
  const at = '2026-07-01T00:00:00.000Z';
  await session.runTx((tx) async {
    await tx.execute(
      'INSERT INTO ${quoted(Tables.users)} '
      '(user_id, first_name, last_name, email, created_at, updated_at, revision) '
      r"VALUES ('user-1', 'Sam', 'Ranger', 'sam@example.com', $1, $1, 0)",
      parameters: [at],
    );
    await tx.execute(
      'INSERT INTO ${quoted(Tables.projects)} '
      '(project_id, project_name, owner_user_id, creation_date, datum, '
      'created_at, updated_at, revision, coordinate_format, '
      'triangulation_window_minutes) '
      r"VALUES ('proj-1', 'P', 'user-1', $1, 'WGS84', $1, $1, 0, 'dd', 15)",
      parameters: [at],
    );
  });
}

Future<void> _insertObservation(
  Session session, {
  required String id,
  required int serverSeq,
  String updatedAt = '2026-07-30T12:00:00.000Z',
}) {
  return session.execute(
    'INSERT INTO ${quoted(Tables.observations)} '
    '(observation_id, project_id, user_id, timestamp_local, timestamp_utc, '
    'timezone_offset, latitude, longitude, position_source, elevation, '
    'altitude_agl, observation_type, signal_type, signal_strength, '
    'created_at, updated_at, revision, server_seq) '
    r"VALUES ($1, 'proj-1', 'user-1', $2, $2, '+00:00', 34.0, -111.0, "
    r"'gps_fix', 2100.0, 0, 'directional', 'regular_pulse', 'strong', "
    r'$2, $3, 1, $4)',
    parameters: [id, '2026-07-30T12:00:00.000Z', updatedAt, serverSeq],
  );
}

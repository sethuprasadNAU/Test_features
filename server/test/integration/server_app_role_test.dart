@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

import '../support/database_test_config.dart';

/// Retries [statement] on Postgres's `XX000` catalog-concurrency errors —
/// the same class `postgres_database.dart`'s `_retryOnConcurrentCatalogUpdate`
/// exists for (task 10.66/10.89), reproduced live here on this file's own
/// `DROP TABLE`/`CREATE TABLE` probe-table churn: `ensureServerAppRole`'s
/// `GRANT ... ON ALL TABLES IN SCHEMA public`, running concurrently from a
/// dozen-plus other Postgres-backed test files, touches this file's probe
/// table's `pg_class` row too, and a `DROP`/`CREATE` racing that update can
/// lose the same way a `GRANT` can. Not exported from `postgres_database.dart`
/// (it is a private helper there), so duplicated at the granularity this
/// file needs rather than widening that library's public surface for one
/// test file.
Future<void> _retryOnConcurrentCatalogRace(
  Future<void> Function() statement,
) async {
  for (var attempt = 1; ; attempt++) {
    try {
      await statement();
      return;
    } on ServerException catch (e) {
      final isConcurrentCatalogRace =
          e.code == 'XX000' &&
          (e.message.contains('tuple concurrently updated') ||
              e.message.contains('tuple concurrently deleted') ||
              e.message.contains('cache lookup failed for relation'));
      if (!isConcurrentCatalogRace || attempt >= 20) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 15 * attempt));
    }
  }
}

/// Task 10.63 / Security Model §12.5, finding J-3: the server's own database
/// connection used to run as a Postgres superuser, which `COPY ... FROM
/// PROGRAM` demonstrated live. This proves the fix — `ensureServerAppRole` /
/// `assumeServerAppRole` in `postgres_database.dart` — against a **real**
/// Postgres, the same reason `postgres_sync_test.dart` exists: a claim about
/// role attributes and grants is not one an in-process fake can make.
///
/// Deliberately touches the real `public` schema rather than a per-test
/// schema like the rest of this suite: `ensureServerAppRole`'s grant is
/// `ON ALL TABLES IN SCHEMA public` by design (production never uses another
/// schema — see the comment on `_hasMigrationsTable`), so a custom test
/// schema would not exercise the grant this test is for. Blast radius is one
/// throwaway table, created and dropped by every test.
void main() {
  late Connection admin;
  const probeTable = 'tritrack_test_10_63_probe';

  setUpAll(() async {
    if (testDatabaseConfig == null) return;
    admin = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await _retryOnConcurrentCatalogRace(
      () => admin.execute('DROP TABLE IF EXISTS $probeTable'),
    );
    await admin.close();
  });

  group('server app role (task 10.63)', skip: databaseSkipReason, () {
    setUp(() async {
      await _retryOnConcurrentCatalogRace(
        () => admin.execute('DROP TABLE IF EXISTS $probeTable'),
      );
      await _retryOnConcurrentCatalogRace(
        () => admin.execute(
          'CREATE TABLE $probeTable (id serial PRIMARY KEY, value text)',
        ),
      );
      await ensureServerAppRole(admin);
    });

    tearDown(() async {
      await _retryOnConcurrentCatalogRace(
        () => admin.execute('DROP TABLE IF EXISTS $probeTable'),
      );
    });

    Future<Connection> openDemoted() async {
      final connection = await Connection.open(
        testDatabaseConfig!.endpoint,
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      );
      addTearDown(connection.close);
      await assumeServerAppRole(connection);
      return connection;
    }

    test('assuming the role removes the superuser attribute', () async {
      final demoted = await openDemoted();
      final result = await demoted.execute(
        'SELECT rolsuper FROM pg_roles WHERE rolname = current_user',
      );
      expect(result.first.first, false);
    });

    test(
      'DML on an existing table still works after assuming the role',
      () async {
        final demoted = await openDemoted();

        await demoted.execute(
          'INSERT INTO $probeTable (value) VALUES (\$1)',
          parameters: ['hello'],
        );
        final selected = await demoted.execute('SELECT value FROM $probeTable');
        expect(selected.first.first, 'hello');

        await demoted.execute(
          'UPDATE $probeTable SET value = \$1',
          parameters: ['bye'],
        );
        await demoted.execute('DELETE FROM $probeTable');
        final afterDelete = await demoted.execute(
          'SELECT count(*) FROM $probeTable',
        );
        expect(afterDelete.first.first, 0);
      },
    );

    test('a table created after ensureServerAppRole is still granted to the '
        'app role, via default privileges (task 10.89)', () async {
      // Deliberately the reverse order from `setUp` above: grant *first*,
      // then create the table, with no second call to
      // `ensureServerAppRole` in between. `ON ALL TABLES` from `setUp`
      // cannot be what makes this table visible — it ran against a schema
      // that did not have this table yet. Only `ALTER DEFAULT PRIVILEGES`
      // can explain a pass here; a regression to a `GRANT ... ON ALL
      // TABLES`-only scheme would make this fail with 42501 while the
      // sibling test above keeps passing, which is the distinction this
      // test exists to catch.
      const laterTable = 'tritrack_test_10_89_probe';
      await admin.execute('DROP TABLE IF EXISTS $laterTable');
      addTearDown(() => admin.execute('DROP TABLE IF EXISTS $laterTable'));
      await admin.execute(
        'CREATE TABLE $laterTable (id serial PRIMARY KEY, value text)',
      );

      final demoted = await openDemoted();
      await demoted.execute(
        'INSERT INTO $laterTable (value) VALUES (\$1)',
        parameters: ['hello'],
      );
      final selected = await demoted.execute('SELECT value FROM $laterTable');
      expect(selected.first.first, 'hello');
    });

    test(
      'COPY ... FROM PROGRAM is refused after assuming the role (finding J-3)',
      () async {
        final demoted = await openDemoted();
        await demoted.execute('CREATE TEMP TABLE probe_program (line text)');
        // Task 10.78, finding K-10: `throwsA(anything)` cannot tell this
        // refusal from a dropped connection, a syntax error, or a missing
        // temp table — every one of those also throws. Asserting Postgres's
        // own `insufficient_privilege` SQLSTATE (42501) is what actually
        // measures "the superuser attribute is gone", the property this test
        // exists to prove; `rolsuper` above already proves the role change
        // took, so `42501` here proves the attribute change is what Postgres
        // is enforcing, not a coincidence of a broken harness.
        await expectLater(
          demoted.execute("COPY probe_program FROM PROGRAM 'id'"),
          throwsA(
            isA<ServerException>().having((e) => e.code, 'SQLSTATE', '42501'),
          ),
        );
      },
    );

    group('the audit tables cannot be erased by the role that writes them '
        '(task 10.83)', () {
      setUp(() async {
        for (final statement in authAuditLogStatements()) {
          await admin.execute(statement);
        }
        for (final statement in syncTrafficLogStatements()) {
          await admin.execute(statement);
        }
        await admin.execute('DELETE FROM auth_audit_log');
        await admin.execute('DELETE FROM sync_traffic_log');
        // Re-run after the tables above are guaranteed to exist, the same
        // way `PostgresMigrations.run` always calls `_ensureServerOnlyTables`
        // immediately before `ensureServerAppRole` — the REVOKE this task
        // adds only means anything once the table it targets is there.
        await ensureServerAppRole(admin);
      });

      Future<void> expectInsufficientPrivilege(Future<void> action) =>
          expectLater(
            action,
            throwsA(
              isA<ServerException>().having((e) => e.code, 'SQLSTATE', '42501'),
            ),
          );

      test('DELETE from auth_audit_log is refused', () async {
        final demoted = await openDemoted();
        await demoted.execute(
          "INSERT INTO auth_audit_log (event) VALUES ('link_requested')",
        );
        await expectInsufficientPrivilege(
          demoted.execute('DELETE FROM auth_audit_log'),
        );
      });

      test('TRUNCATE auth_audit_log is refused', () async {
        final demoted = await openDemoted();
        await expectInsufficientPrivilege(
          demoted.execute('TRUNCATE auth_audit_log'),
        );
      });

      test('DELETE from sync_traffic_log is refused', () async {
        final demoted = await openDemoted();
        await expectInsufficientPrivilege(
          demoted.execute('DELETE FROM sync_traffic_log'),
        );
      });

      test('TRUNCATE sync_traffic_log is refused', () async {
        final demoted = await openDemoted();
        await expectInsufficientPrivilege(
          demoted.execute('TRUNCATE sync_traffic_log'),
        );
      });

      test('ordinary insert-only traffic is unaffected — SELECT and INSERT '
          'still work', () async {
        final demoted = await openDemoted();
        await demoted.execute(
          "INSERT INTO auth_audit_log (event) VALUES ('link_requested')",
        );
        final selected = await demoted.execute(
          'SELECT count(*) FROM auth_audit_log',
        );
        expect((selected.first.first as int) > 0, isTrue);
      });
    });
  });
}

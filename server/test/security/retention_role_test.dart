@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// The credential §4.7's retention sweep runs as (task 11.79).
///
/// ## Why there is a second role at all
///
/// Task 10.83 revoked `DELETE, TRUNCATE` on both audit tables from
/// `tritrack_app` — the role every network-facing connection runs as — having
/// demonstrated 310 rows erased through that exact connection. **So the purge
/// entrypoint could never have worked**: it demoted itself to the app role,
/// with a comment saying that role's DML already covered the deletes. True when
/// it was written; false from the moment 10.83 landed; and **nothing noticed,
/// because nothing ran it.**
///
/// This is the narrower credential `ensureServerAppRole`'s own comment said the
/// sweep would need. These tests hold both halves at once, which is the only
/// interesting thing about them: **the sweep can delete audit rows and the
/// server still cannot.** A change that made the sweep work by re-granting
/// `DELETE` to `tritrack_app` would pass the first half and fail the second.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_retention_role_test';

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
    await PostgresMigrations.run(connection);
    await ensureAuditRetentionRole(connection);
    await connection.execute(
      'INSERT INTO auth_audit_log (occurred_at, event, email) '
      r"VALUES (now() - interval '400 days', 'link_requested', 'sam@x.org')",
    );
  });

  /// Runs [sql] as [role] on a throwaway session, and reports the error code
  /// Postgres raised, or null if it succeeded.
  Future<String?> asRole(String role, String sql) async {
    await connection.execute('SET ROLE "$role"');
    try {
      await connection.execute(sql);
      return null;
    } on ServerException catch (e) {
      return e.code;
    } finally {
      await connection.execute('RESET ROLE');
    }
  }

  group(
    'the sweep can delete, and the server still cannot',
    skip: databaseSkipReason,
    () {
      test('the retention role deletes an over-window audit row', () async {
        await ensureAuditRetentionRole(connection);
        await assumeAuditRetentionRole(connection);
        final swept = await AuditRetentionService(connection).purge();
        await connection.execute('RESET ROLE');

        expect(
          swept.authEvents,
          1,
          reason:
              'this is the whole task: §4.7 says a year, and something has to '
              'be able to enforce it. Watched failing first — the app role '
              'raises "permission denied for table auth_audit_log"',
        );
      });

      test('and the app role still cannot, which is task 10.83 intact', () async {
        // Either refusal is the property: `42501` is "permission denied", and
        // `42P01` is this suite's per-test schema, on which the app role holds
        // no `USAGE` and so cannot resolve the table at all. Both mean the
        // statement did not delete an audit row; asserting one exact code here
        // would be asserting a fact about the test harness rather than about
        // the privilege. In production, where everything is in `public`, it is
        // `42501` — watched there on a real stack.
        final refused = anyOf('42501', '42P01');
        expect(
          await asRole(
            DatabaseConfig.serverAppRoleName,
            'DELETE FROM auth_audit_log',
          ),
          refused,
          reason:
              'a forensic record erasable by whatever compromises the process '
              'that writes it is not one. If making the sweep work meant '
              're-granting DELETE here, the fix reopened what 10.83 closed',
        );
        expect(
          await asRole(
            DatabaseConfig.serverAppRoleName,
            'DELETE FROM sync_traffic_log',
          ),
          refused,
        );
      });
    },
  );

  group('the retention role is narrow', skip: databaseSkipReason, () {
    test('it cannot read field data', () async {
      expect(
        await asRole(
          auditRetentionRoleName,
          'SELECT * FROM ${quoted(Tables.observations)} LIMIT 1',
        ),
        anyOf('42501', '42P01'),
        reason:
            'it exists to delete three tables of bookkeeping. A role that can '
            'also read every bearing on the server is a second copy of the '
            'app role wearing a different name',
      );
    });

    test('it cannot write anywhere, not even where it may delete', () async {
      expect(
        await asRole(
          auditRetentionRoleName,
          'INSERT INTO auth_audit_log (occurred_at, event, email) '
          r"VALUES (now(), 'link_requested', 'forged@x.org')",
        ),
        '42501',
        reason:
            'deleting past a window and writing a new event are different '
            'powers, and this one needs only the first. A retention role that '
            'can INSERT into the audit log can forge history as well as '
            'shorten it',
      );
    });

    test('it is not a credential anybody can log in with', () async {
      final row = await connection.execute(
        'SELECT rolcanlogin, rolsuper, rolbypassrls FROM pg_roles '
        r'WHERE rolname = $1',
        parameters: [auditRetentionRoleName],
      );
      expect(
        row.single,
        [false, false, false],
        reason:
            'like tritrack_app and tritrack_restore, this is a privilege '
            'label assumed with SET ROLE on an already-authenticated admin '
            'connection — never a second password to provision or rotate',
      );
    });
  });

  test('every retention class has a grant, and no grant is spare', () {
    // Task 10.66's rule, and the one that keeps this file honest: a fourth
    // class added to `retentionClasses` with no grant here would sweep nothing
    // and report nothing about why, which is the exact failure this whole task
    // is about.
    expect(
      auditRetentionTables.toSet(),
      retentionClasses.map((c) => c.table).toSet(),
      reason:
          'the privilege list and the sweep list must name the same tables. A '
          'class with no grant sweeps nothing; a grant with no class is '
          'privilege nothing asked for',
    );
  });
}

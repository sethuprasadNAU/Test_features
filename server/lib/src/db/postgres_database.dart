/// Postgres connection, configuration, and migration runner (task 10.5).
library;

import 'dart:io';
import 'dart:math';

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../auth/auth_schema.dart';
import '../diagnostics/sync_traffic_log.dart';
import '../projects/invite_schema.dart';
import '../projects/join_schema.dart';
import '../projects/project_destruction_service.dart';
import '../schema/postgres_schema.dart';
import '../security/audit_log.dart';
import '../security/placeholder_secrets.dart';
import '../sync/cursor_store.dart';
import '../sync/database_identity.dart';
import '../sync/revision_anomaly_log.dart';
import '../sync/server_seq.dart';
import '../sync/tombstone_retention_service.dart';

/// Connection settings, read from the environment only.
///
/// No fallback default for the password, per `TriTrack_Security_Model.md` §4.6
/// — a working default is how a prototype reaches production with a known
/// credential. Missing configuration throws at startup, which is loud,
/// immediate, and harmless compared to the alternative.
class DatabaseConfig {
  const DatabaseConfig({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
  });

  final String host;
  final int port;
  final String database;
  final String username;
  final String password;

  /// The role every persistent, network-facing server connection runs SQL as
  /// (task 10.63 / Security Model §12.5, finding J-3).
  ///
  /// `config.username` above (`POSTGRES_USER`) is a superuser on the official
  /// `postgres` image — that is what let `COPY … FROM PROGRAM` demonstrate
  /// arbitrary command execution on the database container, live, from
  /// exactly the credential the connection that answers the network holds.
  /// Task 10.59 (finding I-10) closed this on the restore path with a
  /// `NOSUPERUSER` role and `SET ROLE`, reasoned about in
  /// `server/backup/restore.sh`; this is the same fix for the connection that
  /// is open every second the server runs, which 10.59 did not touch.
  ///
  /// `NOSUPERUSER` is what actually removes `COPY … FROM PROGRAM` — that
  /// capability checks the superuser attribute, not a `GRANT`-able privilege,
  /// so no grant made below can hand it back. `NOLOGIN`, for the same reason
  /// `tritrack_restore` is: this is a privilege label assumed with `SET ROLE`
  /// on a connection already authenticated as the admin user, never a second
  /// credential to provision or rotate.
  static const String serverAppRoleName = 'tritrack_app';

  factory DatabaseConfig.fromEnvironment([Map<String, String>? env]) {
    final environment = env ?? Platform.environment;
    String required(String key, {bool isSecret = false}) {
      final value = environment[key];
      if (value == null || value.isEmpty) {
        // Names the missing variable but never echoes any value — a
        // configuration error message must not become a way to read secrets
        // out of a log (§4.7's never-log rules).
        throw StateError(
          'Missing required environment variable $key. '
          'Copy .env.example to .env and fill it in — see the README.',
        );
      }
      if (isSecret && isPlaceholderSecret(value)) {
        // §4.6 requires refusing to start on a *placeholder*, not only on a
        // missing value. A password of `changeme` is the mechanism by which a
        // prototype reaches production with a known credential — it satisfies
        // every "is it set?" check while being no secret at all. Note this
        // message names the variable and not the value, same as above.
        throw StateError(
          'Environment variable $key is set to a known placeholder value. '
          'Generate a real secret — see the rotation procedure in '
          'server/README.md (Security Model §4.6).',
        );
      }
      return value;
    }

    return DatabaseConfig(
      host: required('POSTGRES_HOST'),
      port: int.tryParse(environment['POSTGRES_PORT'] ?? '5432') ?? 5432,
      database: required('POSTGRES_DB'),
      username: required('POSTGRES_USER'),
      password: required('POSTGRES_PASSWORD', isSecret: true),
    );
  }

  Endpoint get endpoint => Endpoint(
    host: host,
    port: port,
    database: database,
    username: username,
    password: password,
  );
}

/// Creates [DatabaseConfig.serverAppRoleName] if it does not exist and grants
/// it exactly what the server's ongoing traffic does: read and write rows in
/// tables that already exist (task 10.63).
///
/// Run on every start, as admin, immediately after the schema is ensured —
/// same reasoning as [PostgresMigrations._ensureServerOnlyTables]: a table
/// added by a later migration must be granted to the app role on the very
/// run that creates it, or every connection that has already called
/// [assumeServerAppRole] loses access to it. `GRANT ... ON ALL TABLES` is a
/// snapshot, not a standing rule, so re-granting here — cheaply, since it is
/// idempotent — is what keeps the role's privileges in step with the schema
/// instead of one release behind it.
///
/// `GRANT "$role" TO CURRENT_USER` makes the `SET ROLE` below work even if
/// the admin connection is ever a non-superuser: a superuser can `SET ROLE`
/// to anything with no prior grant, but membership is what a non-superuser
/// needs, and granting it unconditionally costs nothing when it already
/// holds it.
///
/// `server_seq` itself is a locked counter row, not a Postgres `SEQUENCE`
/// (see the comment on that decision below) — but `auth_audit_log` and
/// `sync_traffic_log` (`security/audit_log.dart`, `diagnostics/
/// sync_traffic_log.dart`) each declare `id BIGSERIAL PRIMARY KEY`, which
/// **is** an implicit sequence, and `INSERT` into either needs `USAGE` on it.
/// Caught by `test/integration/server_app_role_test.dart`, which failed with
/// `permission denied for sequence ..._id_seq` on the first run of this
/// function without this grant — exactly the class 10.66 asks every
/// remediation to check for, on the first attempt at this one.
///
/// Also sets `ALTER DEFAULT PRIVILEGES` for tables and sequences created by
/// this connection's role from now on (task 10.89) — see the comment on
/// those two statements below for why the `GRANT ... ON ALL ...` calls above
/// are not sufficient on their own.
Future<void> ensureServerAppRole(Session session) async {
  final role = DatabaseConfig.serverAppRoleName;
  // Task 10.69: this used to be check-then-create (`SELECT ... pg_roles` then
  // `CREATE ROLE` if absent), which races when two connections run it
  // concurrently — as they do in practice, since every test file that touches
  // the database calls this during setup and `dart test` runs files
  // concurrently by default. Both connections could see `exists.isEmpty` and
  // both attempt the `CREATE ROLE`, and the loser crashed instead of finding
  // the role already there. Trying it unconditionally and swallowing only
  // the "someone else just created it" errors closes the race instead of
  // narrowing it — measured with a harness that opens N connections and
  // fires this concurrently (task 10.69), losing connections surfaced *two*
  // distinct SQLSTATEs depending on timing: 42710 (duplicate_object, the
  // `pg_roles` catalog check) and 23505 (unique_violation, on the underlying
  // `pg_authid` index) — so both must be swallowed, not just the one the
  // non-concurrent case suggests.
  try {
    await session.execute(
      'CREATE ROLE "$role" '
      'NOSUPERUSER NOCREATEDB NOCREATEROLE NOLOGIN NOREPLICATION NOBYPASSRLS',
    );
  } on ServerException catch (e) {
    if (e.code != '42710' && e.code != '23505') rethrow;
  }
  await session.execute('GRANT "$role" TO CURRENT_USER');
  // Task 10.89: every catalog-mutating GRANT/ALTER below shares one hazard —
  // two connections racing the *same* target row (`pg_class.relacl` for a
  // table-level GRANT, `pg_default_acl` for the statements further down)
  // can lose to Postgres's own concurrent-update check and surface `XX000`
  // "tuple concurrently updated" instead of blocking and succeeding. This
  // was found on the `ON ALL TABLES` line below — not one of the new
  // statements this task added — reproduced live once the full suite's
  // dozen-plus Postgres-backed test files were calling this function from
  // their own `setUp`s concurrently, at the volume this task's own new
  // `ALTER DEFAULT PRIVILEGES` calls added. Wrapping every statement here,
  // not only the ones that happened to be observed racing, is task 10.66's
  // standing rule: fix the class, not the instance that got caught.
  // Task 10.83: the grant this statement makes hands `$role` DELETE on every
  // table, `auth_audit_log` and `sync_traffic_log` included — and that role
  // is the one every persistent, network-facing connection runs as. C-5's
  // whole point was a forensic record of denials; a record erasable by
  // whatever compromises the process that writes it is not one. Demonstrated
  // live: 310 rows removed from `auth_audit_log` through this exact
  // connection.
  //
  // The grant and the narrowing revoke below run inside **one transaction**,
  // not two independently-committed statements — a connection that observed
  // this grant committed but not yet narrowed would see DELETE genuinely
  // available on the audit tables, and with a dozen-plus Postgres-backed
  // test files calling this function from their own `setUp`s concurrently,
  // that window was wide enough to let a live `DELETE` through (task 10.83's
  // own test caught it, run alongside the rest of the suite rather than
  // alone). A transaction makes the narrower privilege set atomic: nothing
  // outside this call ever observes DELETE granted on these two tables
  // without the revoke already applied.
  await _retryOnConcurrentCatalogUpdate(() async {
    await session.execute('BEGIN');
    try {
      await session.execute(
        'GRANT SELECT, INSERT, UPDATE, DELETE '
        'ON ALL TABLES IN SCHEMA public TO "$role"',
      );
      // Schema-qualified (`public.auth_audit_log`), deliberately, unlike the
      // unqualified table names used elsewhere in this function. A
      // connection whose `search_path` puts a per-test schema ahead of
      // `public` — most of this suite's Postgres-backed test files, by
      // design, each with their own copy of every server-only table — would
      // otherwise resolve an unqualified `auth_audit_log` to *that* schema's
      // table and narrow the wrong one, leaving `public.auth_audit_log`
      // re-widened by the grant above on every such call and never revoked.
      // Reproduced live: this task's own test passed run alone and failed
      // inside the full suite until this qualifier was added — the
      // unqualified form is task 10.66's class, not an isolated typo, since
      // every other statement in this function is unqualified and correct
      // only because none of them names a specific table the way this one
      // must.
      //
      // `42P01` (undefined_table) is swallowed, not surfaced: in every real
      // caller — [PostgresMigrations.run] — `_ensureServerOnlyTables` has
      // already created both tables by the time this function runs, so the
      // revoke always has something to narrow. The only way to reach a
      // missing table here is a caller (a test, most likely) that assumes
      // the role without first ensuring the schema, and that caller has
      // nothing for this statement to protect yet either.
      try {
        await session.execute(
          'REVOKE DELETE, TRUNCATE ON public.auth_audit_log, '
          'public.sync_traffic_log FROM "$role"',
        );
      } on ServerException catch (e) {
        if (e.code != '42P01') rethrow;
      }
      await session.execute('COMMIT');
    } catch (_) {
      await session.execute('ROLLBACK');
      rethrow;
    }
  });
  // If a retention purge (task 10.81) ever needs to delete rows from either
  // audit table, it must run under a separate, narrower-scoped credential
  // rather than reopening the grant above on `$role` — the two are not to
  // end up fighting each other's fix.
  await _retryOnConcurrentCatalogUpdate(
    () => session.execute(
      'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "$role"',
    ),
  );
  // Task 10.89: `GRANT ... ON ALL TABLES/SEQUENCES` above is a snapshot of
  // what exists *right now* — Postgres never extends a `GRANT` to an object
  // created afterwards, regardless of when or how often the statement is
  // re-run. Every table and sequence this schema currently has is covered
  // because [PostgresMigrations.run] always calls this function again,
  // unconditionally, immediately after any DDL it just ran — that call-site
  // discipline is *why* the snapshot above stays in step today, not a
  // property `GRANT` gives for free. `ALTER DEFAULT PRIVILEGES` is the
  // difference between "in step because every caller remembers to re-grant"
  // and "in step because Postgres enforces it": it tells Postgres to attach
  // these same privileges to any table or sequence *this role* (the admin
  // connection `ensureServerAppRole` runs on) creates in `public` from this
  // point on, with no second call required — so a future DDL path that
  // doesn't funnel through [PostgresMigrations.run], or a refactor that
  // reorders it, fails safe instead of silently reopening this hole. Only
  // tables and sequences exist in this schema (no views, functions, or
  // types), so those are the only two object classes to cover. Same
  // concurrent-update hazard as the `GRANT`s above, so the same retry.
  await _retryOnConcurrentCatalogUpdate(
    () => session.execute(
      'ALTER DEFAULT PRIVILEGES IN SCHEMA public '
      'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$role"',
    ),
  );
  await _retryOnConcurrentCatalogUpdate(
    () => session.execute(
      'ALTER DEFAULT PRIVILEGES IN SCHEMA public '
      'GRANT USAGE, SELECT ON SEQUENCES TO "$role"',
    ),
  );
}

/// Retries [statement] when two sessions race the same catalog row: "tuple
/// concurrently updated" (a table's `pg_class.relacl` for a `GRANT`, or a
/// `pg_default_acl` row for `ALTER DEFAULT PRIVILEGES`), "tuple concurrently
/// deleted" (the same race, losing side observes a delete instead of an
/// update), "cache lookup failed for relation" (a statement's plan holds
/// an OID for a table another session drops mid-execution — this suite's own
/// `server_app_role_test.dart` churns a throwaway probe table in `public` on
/// every test, which is exactly this), or a `23505` unique violation on
/// `pg_default_acl` (both sessions inserting that row rather than updating
/// it — the fresh-database case, task 11.64). One class, four messages
/// Postgres uses for it, and the first three are `XX000` while the fourth is
/// not; see the comment in [ensureServerAppRole]. Eight attempts
/// with a short, jittered, back-off delay is generous for a catalog update
/// that normally completes in microseconds; if it is still colliding after
/// that many rounds, something other than this ordinary race is wrong and
/// the error should surface.
Future<void> _retryOnConcurrentCatalogUpdate(
  Future<void> Function() statement,
) async {
  for (var attempt = 1; ; attempt++) {
    try {
      await statement();
      return;
    } on ServerException catch (e) {
      // Task 11.64 added the fourth message, and it is the same race with a
      // different sign. When two sessions *update* the same `pg_default_acl`
      // row Postgres reports `XX000 tuple concurrently updated`; when they
      // both try to **insert** it — the first time either has run against a
      // fresh database, which is every parallel test file's setup — the
      // loser gets `23505` on that catalog's unique index instead. The
      // server suite went red on it on 2026-08-30 mid-gate, in
      // `closed_membership_disclosure_test.dart`, having been green in the
      // pass before: a flaky suite is the one thing Gate C criterion 4
      // cannot tolerate, because "green in one pass" then means "green in
      // the pass we looked at".
      //
      // **Narrowed to that one catalog on purpose.** A blanket `23505` retry
      // here would silently re-run an application-level unique violation
      // twenty times and then report the original error anyway — slower, and
      // hiding a real constraint failure behind a race that was not
      // happening.
      final isConcurrentCatalogInsert =
          e.code == '23505' && e.message.contains('pg_default_acl');
      final isConcurrentCatalogRace =
          isConcurrentCatalogInsert ||
          (e.code == 'XX000' &&
              (e.message.contains('tuple concurrently updated') ||
                  e.message.contains('tuple concurrently deleted') ||
                  e.message.contains('cache lookup failed for relation')));
      if (!isConcurrentCatalogRace || attempt >= 20) rethrow;
      await Future<void>.delayed(
        Duration(milliseconds: 15 * attempt) +
            Duration(milliseconds: Random().nextInt(30)),
      );
    }
  }
}

/// Demotes the rest of this connection's session to
/// [DatabaseConfig.serverAppRoleName] (task 10.63). Call once, right after
/// [ensureServerAppRole] has run on *some* connection to this database (not
/// necessarily this one) and before this connection serves any request —
/// every statement after this one, for the life of the connection, runs
/// without the superuser attribute.
Future<void> assumeServerAppRole(Session session) async {
  await session.execute('SET ROLE "${DatabaseConfig.serverAppRoleName}"');
}

/// The role §4.7's retention sweep runs as (task 11.79).
///
/// **It exists because `tritrack_app` deliberately cannot delete audit rows.**
/// Task 10.83 revoked `DELETE, TRUNCATE` on `auth_audit_log` and
/// `sync_traffic_log` from the role every network-facing connection runs as,
/// having demonstrated 310 rows erased through that exact connection: a
/// forensic record erasable by whatever compromises the process that writes it
/// is not one.
///
/// Which means the retention purge could never have worked as written.
/// `bin/purge_audit_logs.dart` demoted itself to `tritrack_app` with a comment
/// saying "the DML the app role holds already covers that" — true when it was
/// written, false from the moment 10.83 landed. **Nothing noticed, because
/// nothing ran it.** So this task found not one broken remedy but two stacked:
/// a command that could not run in the shipped image, over a permission it no
/// longer had. [ensureServerAppRole]'s own comment named the fix — "it must run
/// under a separate, narrower-scoped credential rather than reopening the grant
/// above" — and this is it.
///
/// **What it may do: read and delete, on exactly the three retention tables.**
/// Nothing else, on nothing else. It cannot read an observation, cannot write
/// anywhere, and — being `NOLOGIN` — is not a credential at all: it is a
/// privilege label assumed with `SET ROLE` on a connection already
/// authenticated as the admin user, the same arrangement `tritrack_app` and
/// `tritrack_restore` use. **10.83's property is intact:** the long-lived
/// server connection never assumes this role, so a compromise of the server
/// process still cannot erase the record of itself.
const String auditRetentionRoleName = 'tritrack_retention';

/// Creates [auditRetentionRoleName] and grants it read-and-delete on the
/// retention tables, in whichever schema this connection is pointed at.
///
/// Unqualified table names, unlike task 10.83's revoke one function up: that
/// one had to name `public` because it was narrowing a privilege and had to
/// narrow the *real* table; this one grants inside the caller's own
/// `search_path`, which is what makes it work for the per-test schemas this
/// suite creates. Same concurrent-catalog-update hazard as every grant in
/// [ensureServerAppRole], so the same retry.
Future<void> ensureAuditRetentionRole(Session session) async {
  try {
    await session.execute(
      'CREATE ROLE "$auditRetentionRoleName" '
      'NOSUPERUSER NOCREATEDB NOCREATEROLE NOLOGIN NOREPLICATION NOBYPASSRLS',
    );
  } on ServerException catch (e) {
    // Task 10.69's race, identically: every test file's setUp calls this.
    if (e.code != '42710' && e.code != '23505') rethrow;
  }
  await session.execute('GRANT "$auditRetentionRoleName" TO CURRENT_USER');
  final schema =
      (await session.execute('SELECT current_schema()')).first.first! as String;
  await _retryOnConcurrentCatalogUpdate(
    () => session.execute(
      'GRANT USAGE ON SCHEMA "$schema" TO "$auditRetentionRoleName"',
    ),
  );
  for (final table in auditRetentionTables) {
    await _retryOnConcurrentCatalogUpdate(() async {
      try {
        await session.execute(
          'GRANT SELECT, DELETE ON $table TO "$auditRetentionRoleName"',
        );
      } on ServerException catch (e) {
        // The table not existing yet is the caller's problem to notice, not a
        // reason to fail the grant of the other two — and a purge against a
        // table that is not there has nothing to delete anyway.
        if (e.code != '42P01') rethrow;
      }
    });
  }
}

/// The tables [auditRetentionRoleName] may touch. Derived from nothing else on
/// purpose: this is a privilege boundary, and it should be legible as a list.
/// `retention_test.dart` asserts it matches `retentionClasses`, so a fourth
/// class added there without a grant here fails loudly rather than silently
/// skipping its sweep.
const List<String> auditRetentionTables = [
  'auth_audit_log',
  'sync_traffic_log',
  'project_join_requests',
];

/// Demotes the rest of this connection's session to [auditRetentionRoleName].
Future<void> assumeAuditRetentionRole(Session session) async {
  await session.execute('SET ROLE "$auditRetentionRoleName"');
}

/// Runs the server's schema migrations.
///
/// Deliberately mirrors the app's `runMigrations` shape (forward-only, ordered,
/// recorded so it can resume) rather than inventing a different scheme, since
/// the two schemas have to stay in step and task 10.11's version-skew policy
/// compares them.
///
/// Version 1 builds the whole current schema in one step. That is correct
/// because **no server database exists anywhere yet** — there is no deployed
/// instance to upgrade incrementally from. The app's five SQLite versions are
/// history that had to be preserved for devices in the field; the server has no
/// such history to honour, so replaying it would be theatre. From the *next*
/// schema change onward, the server gets an additive migration per version like
/// the app does, and its recorded version must track `latestSchemaVersion`.
abstract final class PostgresMigrations {
  /// The shared schema version this server's schema implements.
  static int get targetVersion => latestSchemaVersion;

  /// Applies anything not yet recorded in `schema_migrations`.
  ///
  /// **A migration statement that returns rows is a report, and every row it
  /// returns is written to [log]** — the server's startup output, by default
  /// — prefixed with the version being applied. DDL, `UPDATE` and `DO`
  /// return no rows, so the only lines this produces are the ones a
  /// migration writes on purpose. Task 11.227 added it for `schemaV14Statements`'
  /// deletion of tags linked to no project: a deletion inside a migration is
  /// loud or it is a bug, the Postgres driver discards `RAISE NOTICE`, and
  /// nothing else in this loop had ever said what it did. One line per
  /// version applied goes to the same place, so an upgrade that ran is
  /// distinguishable from one that had nothing to do.
  /// [upTo] stops after that schema version instead of running everything to
  /// [targetVersion]. **It exists so `postgres_migration_upgrade_test` can
  /// assert the state a populated database is left in *between* two
  /// versions**, and production passes nothing — a server that stopped short
  /// would announce a version the wire refuses and be worse than one that
  /// had not started.
  ///
  /// Task 11.243 needed it: schema v17 empties every table the versions
  /// before it populate (`ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §9), so a test
  /// that runs the whole path can only ever assert the wipe, and what v14
  /// and v16 do to real rows would stop being checked at all.
  static Future<void> run(
    Session session, {
    void Function(String line) log = print,
    int? upTo,
  }) async {
    final bootstrapped = await _hasMigrationsTable(session);
    if (!bootstrapped) {
      for (final statement in schemaStatements()) {
        await session.execute(statement);
      }
      await _ensureServerOnlyTables(session);
      await session.execute(
        r'INSERT INTO schema_migrations (version) VALUES ($1)',
        parameters: [targetVersion],
      );
      // Task 10.63: the app role must exist, with every table granted,
      // before any connection can [assumeServerAppRole] — including the very
      // one that just bootstrapped this database.
      await ensureServerAppRole(session);
      return;
    }

    // **Server-only tables are ensured on every start, not only at bootstrap.**
    // They are not part of `latestSchemaVersion` — that number describes the
    // *shared* row schema both sides speak, and bumping it to add a table the
    // client has no concept of would force every device in the field to update
    // for a piece of server bookkeeping. But that also means adding one is
    // invisible to the version check below, so a database bootstrapped before
    // it existed would never get it.
    //
    // This is not hypothetical: task 10.11 added `tombstone_purge_floor` and
    // every already-running server started returning 500s on push, because
    // `run` saw a recorded version it already had and returned early. The same
    // trap was latent for `sync_cursors` and the auth tables from the moment
    // they were added. Every statement in this group is `IF NOT EXISTS`, so
    // running it unconditionally is a cheap no-op on an up-to-date database.
    await _ensureServerOnlyTables(session);
    // Same reasoning, task 10.63: re-grant on every start, unconditionally,
    // so a table this run just added via `_ensureServerOnlyTables` (or a
    // migration below) is never one release behind what the app role can
    // reach. Placed before the early return so an up-to-date database still
    // gets the grant re-applied on every start.
    await ensureServerAppRole(session);

    final target = upTo ?? targetVersion;
    final applied = await appliedVersions(session);
    if (applied.contains(target)) return;

    // Apply each recorded-as-missing version in ascending order. Task 10.35
    // added the first entry to [serverMigrations]; before it, reaching this
    // point was always fatal.
    //
    // Each version runs in its own transaction and records itself in the same
    // one, so a failure part-way through a multi-version upgrade leaves the
    // database at the last version that fully succeeded rather than somewhere
    // between two. Interrupting is then safe: re-running resumes from there.
    final current = applied.isEmpty
        ? 0
        : applied.reduce((a, b) => a > b ? a : b);
    for (var version = current + 1; version <= target; version++) {
      final build = serverMigrations[version];
      if (build == null) {
        // Fail loudly rather than guessing: a half-migrated sync server is
        // worse than an unavailable one, and the app is fully usable offline
        // while this gets sorted out (§1.5, fail closed).
        throw StateError(
          'Server database is at schema version(s) $applied but this build '
          'targets v$targetVersion, and no migration path is defined for '
          'v$version. Add the migration before deploying.',
        );
      }
      await session.execute('BEGIN');
      try {
        for (final statement in build()) {
          final result = await session.execute(statement);
          for (final row in result) {
            log('schema v$version: ${row.toList().join(' ')}');
          }
        }
        await session.execute(
          r'INSERT INTO schema_migrations (version) VALUES ($1)',
          parameters: [version],
        );
        await session.execute('COMMIT');
      } catch (_) {
        await session.execute('ROLLBACK');
        rethrow;
      }
      log('schema v$version: applied');
    }
    // A migration in the loop above may have just created a table; grant it
    // to the app role in this same run rather than waiting for the next
    // restart to notice.
    await ensureServerAppRole(session);
  }

  /// Creates the tables that are the server's own business — auth state (10.6),
  /// project invitations (11.2), the project join code and its requests (11.81), sync cursors (10.7), the tombstone purge floor
  /// (10.11), the sync traffic log (10.13), and the authentication audit log
  /// (10.14) — none of which are derived from `tableSpecs` or covered by
  /// `latestSchemaVersion`.
  ///
  /// Idempotent by construction: every statement is `IF NOT EXISTS`, so this is
  /// safe to run on every start and is what makes adding a server-only table
  /// possible without a shared schema bump. See the comment in [run].
  static Future<void> _ensureServerOnlyTables(Session session) async {
    for (final statement in [
      ...authSchemaStatements(),
      ...inviteSchemaStatements(),
      ...joinSchemaStatements(),
      ...syncCursorStatements(),
      // Task 11.58: which database this is. Minted here, on the first start
      // that finds none — so a database restored from this project's backup,
      // which carries the table but not its row, gets a new one.
      ...databaseIdentityStatements(),
      ...tombstonePurgeFloorStatements(),
      // Task 11.290: a scheduled project destruction, and the record that
      // one happened. Ensured on every start for the reason every line here
      // is — a running server bootstrapped before it existed must get it.
      ...projectDestructionStatements(),
      ...syncTrafficLogStatements(),
      ...authAuditLogStatements(),
      ...revisionAnomalyLogStatements(),
    ]) {
      await session.execute(statement);
    }
  }

  static Future<bool> _hasMigrationsTable(Session session) async {
    // Unqualified on purpose, so it resolves through `search_path` rather than
    // only ever looking in `public`. Hardcoding `public.` made `run` claim the
    // database was un-bootstrapped whenever the server pointed at any other
    // schema, so it re-ran the whole DDL and failed on "relation already
    // exists" — migrations were not actually idempotent outside `public`.
    final result = await session.execute(
      "SELECT to_regclass('schema_migrations') IS NOT NULL",
    );
    return result.first.first == true;
  }

  static Future<Set<int>> appliedVersions(Session session) async {
    final result = await session.execute(
      'SELECT version FROM schema_migrations ORDER BY version',
    );
    return result.map((row) => row.first as int).toSet();
  }
}

/// The real [SeqCounterStore]: a single `UPDATE ... RETURNING` against the
/// counter row, run inside the caller's transaction.
///
/// The transaction is supplied rather than opened here, and that is the whole
/// point — the row lock this statement takes is only useful while the
/// caller's own writes are still uncommitted. See `server_seq.dart` and
/// `postgres_schema.dart` for why.
class PostgresSeqCounterStore implements SeqCounterStore {
  const PostgresSeqCounterStore(this.session);

  /// Must be a session inside an open transaction.
  final Session session;

  @override
  Future<int> bumpAndReturn(int by) async {
    final result = await session.execute(
      r'UPDATE sync_seq_counter SET next_value = next_value + $1 '
      r'WHERE only_row RETURNING next_value',
      parameters: [by],
    );
    if (result.isEmpty) {
      throw StateError(
        'sync_seq_counter has no row — the schema was not seeded. '
        'Run migrations before accepting writes.',
      );
    }
    return result.first.first! as int;
  }
}

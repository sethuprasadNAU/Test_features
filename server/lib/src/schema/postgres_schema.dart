/// Generates the server's Postgres DDL from the canonical column set in
/// `package:tritrack_sync` (task 10.5).
///
/// Generated rather than hand-written for one reason: the app's SQLite DDL and
/// this must describe the same schema, and the only way to guarantee that
/// without a second source of truth is to derive both from one declaration.
/// The app can't share DDL *strings* (SQLite dialect, and shipped migrations
/// must never be edited), so it shares the *column set* and each side is
/// tested against it.
library;

import 'package:tritrack_sync/tritrack_sync.dart';

/// Server-only bookkeeping columns, present on every synced table and
/// deliberately **absent from `tableSpecs`**.
///
/// - **`server_seq`** — the delta cursor's clock. Answers only "in what order
///   did the server learn about this row," which is precisely what a cursor
///   needs and what `updated_at` cannot provide across devices with skewed
///   clocks. It does **not** participate in last-write-wins: `revision` then
///   `updated_at` then `origin_device_id` decide *which row wins*, via the
///   shared `MergeResolver`. Nullable, because a row can exist on the server
///   before it has been assigned a sequence within a transaction, and because
///   nothing client-side may ever require it (Phase 10 invariant 3).
///
///   **`server_seq` is not a row identity — it changes.** Every accepted write
///   to a row (insert *or* update) assigns a fresh, higher value, which is
///   what makes the row redeliverable to devices whose cursor predates the
///   change. Do not treat it as stable.
///
/// - **`received_at`** — the server's own clock reading when it accepted this
///   row, used for clock-skew detection. Kept as `timestamptz` (unlike the
///   client-supplied timestamps below) because it is server-generated and
///   never round-trips to a client as an authoritative field.
///
/// - **`clock_skew_flag`** — the skew classification computed at receive time
///   (see `ClockSkew`). Denormalised deliberately: the diagnostics console
///   (10.13) needs "show me the skewed rows" to be a cheap indexed query, and
///   the client timestamps are stored as `text` so SQL-side date arithmetic
///   would be awkward. It records what the server concluded *at the time*,
///   which is what an audit wants even if the rule is later tightened.
const List<String> serverOnlyColumns = [
  'server_seq BIGINT',
  'received_at TIMESTAMPTZ NOT NULL DEFAULT now()',
  'clock_skew_flag TEXT',
];

/// The single-row counter that hands out `server_seq` values.
///
/// **Why a counter row and not a Postgres `SEQUENCE`/`IDENTITY` — read this
/// before "optimising" it.** `nextval()` does not lock, so sequence values are
/// handed out in request order but transactions commit in an unrelated order.
/// That breaks a `WHERE server_seq > cursor` cursor in a way that silently
/// loses data:
///
/// 1. Transaction A takes `server_seq = 100`; transaction B takes `101`.
/// 2. B commits first. A is still open.
/// 3. A client pulls, sees row `101`, and advances its cursor to `101`.
/// 4. A commits, writing row `100`.
/// 5. That client's next pull asks for `> 101`. **Row 100 is never delivered
///    to it — ever.**
///
/// Nothing surfaces that: no error, no conflict, just an observation that
/// quietly never arrives on one device. Exactly the "sync silently
/// incomplete" failure this task exists to prevent.
///
/// `UPDATE ... RETURNING` on a single row takes a row-level write lock held
/// until commit, so a transaction cannot obtain a higher value until the
/// holder of the lower one has committed. Assignment order therefore *equals*
/// commit order, and a reader that can see sequence *n* is guaranteed to be
/// able to see everything below it.
///
/// The cost is that accepted writes serialise on this row. At this
/// application's scale — a handful of field devices, a few pushes a minute —
/// that is irrelevant, and correctness of the field record is not a fair
/// trade for throughput we do not need. If this ever genuinely becomes a
/// bottleneck, the fix is *not* a bare sequence; it is a commit-ordered
/// alternative (e.g. `pg_current_snapshot()`-based cursors), which is a
/// deliberate redesign with its own tests, not a one-line swap.
const String createSyncSeqCounter = '''
CREATE TABLE sync_seq_counter (
  only_row BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (only_row),
  next_value BIGINT NOT NULL DEFAULT 0
)''';

const String seedSyncSeqCounter =
    'INSERT INTO sync_seq_counter (only_row, next_value) VALUES (TRUE, 0)';

/// Tracks which server migrations have run. Server-only — the *shared* schema
/// version lives in `latestSchemaVersion` and is what task 10.11's version-skew
/// policy compares against.
const String createSchemaMigrations = '''
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
)''';

/// Postgres type for a shared [ColumnType].
///
/// **The client-supplied timestamp columns stay `TEXT`, not `TIMESTAMPTZ`, and
/// that is deliberate.** `MergeResolver` compares `updated_at` values that
/// originate on devices, and `DbCodec` defines their exact encoding. Storing
/// them as a Postgres timestamp would re-render them on the way out, so a row
/// could come back byte-different from how a peer wrote it — breaking both
/// last-write-wins tie-breaks and convergence with peers that never saw the
/// server. The server stores what the device wrote, verbatim. `received_at`
/// is the one timestamp that is genuinely the server's own, so it is a real
/// `TIMESTAMPTZ`.
String postgresType(ColumnType type) => switch (type) {
  ColumnType.text => 'TEXT',
  ColumnType.real => 'DOUBLE PRECISION',
  ColumnType.integer => 'BIGINT',
};

/// `CREATE TABLE` for one shared table, plus the server-only columns.
String createTableFor(TableSpec spec) {
  final lines = <String>[
    for (final column in spec.columns)
      '  ${column.name} ${postgresType(column.type)}'
          '${spec.isNotNull(column) ? ' NOT NULL' : ''}',
    for (final column in serverOnlyColumns) '  $column',
  ];
  final pk = spec.primaryKeyColumns.map((c) => c.name).join(', ');
  lines.add('  PRIMARY KEY ($pk)');
  return 'CREATE TABLE ${quoted(spec.name)} (\n${lines.join(',\n')}\n)';
}

/// The schema's table names are mixed-case (`Users`, `Non_Detections`) because
/// that is what every existing backup payload and the shared `Tables`
/// constants use. Postgres folds unquoted identifiers to lower case, so every
/// reference to a table must be double-quoted or `Users` silently becomes
/// `users` and stops matching the shared constant.
String quoted(String identifier) => '"$identifier"';

/// Foreign keys mirroring the app's SQLite schema, as
/// `(table, columns, referencedTable, referencedColumns)`.
///
/// The column sides are lists because task 10.35 made
/// `Observations.session_id` reference a project-scoped key: once
/// `Triangulation_Sessions` is keyed `(session_id, project_id)`, a
/// single-column reference names no unique key and Postgres rejects it.
///
/// **Task 11.219 made every reference into `Tags` composite for the same
/// reason.** A tag is keyed `(tag_id, project_id)` now, so five references
/// widened — and each is a *same-project* reference, exactly the shape
/// `Observations.(session_id, project_id)` already had. The remaining
/// single-column ones point at `Users` (still global) or `Projects` (whose
/// key *is* the project scope).
///
/// **All are `DEFERRABLE INITIALLY DEFERRED`** — checked at commit rather than
/// per statement. A sync push legitimately arrives as a batch whose rows
/// reference each other, and requiring the server to insert in a particular
/// order to satisfy per-statement checks would make correctness depend on
/// iteration order in the protocol layer (10.7). Deferred checks keep the
/// integrity guarantee while making intra-transaction ordering a non-issue.
///
/// `last_modified_by` is intentionally **not** a foreign key, matching the app
/// (`schema.dart`'s note): a merged row may legitimately reference a user row
/// that has not synced yet.
const List<(String, List<String>, String, List<String>)> foreignKeys = [
  (Tables.userEmails, ['user_id'], Tables.users, ['user_id']),
  (Tables.projects, ['owner_user_id'], Tables.users, ['user_id']),
  (Tables.projectMemberships, ['project_id'], Tables.projects, ['project_id']),
  (Tables.projectMemberships, ['user_id'], Tables.users, ['user_id']),
  // Task 11.240. The animal is project-scoped.
  //
  // **Task 11.243 removed `Tags.(individual_id, project_id)` from this
  // list** — the column is gone, and the link between a collar and an animal
  // is `Deployments`, which references both ends. Both of its references are
  // same-project composites and neither is nullable: a deployment with no
  // tag or no animal is not a deployment.
  (Tables.individuals, ['project_id'], Tables.projects, ['project_id']),
  (Tables.deployments, ['project_id'], Tables.projects, ['project_id']),
  (
    Tables.deployments,
    ['tag_id', 'project_id'],
    Tables.tags,
    ['tag_id', 'project_id'],
  ),
  (
    Tables.deployments,
    ['individual_id', 'project_id'],
    Tables.individuals,
    ['individual_id', 'project_id'],
  ),
  (
    Tables.triangulationSessions,
    ['project_id'],
    Tables.projects,
    ['project_id'],
  ),
  (
    Tables.triangulationSessions,
    ['tag_id', 'project_id'],
    Tables.tags,
    ['tag_id', 'project_id'],
  ),
  (Tables.observations, ['project_id'], Tables.projects, ['project_id']),
  (Tables.observations, ['user_id'], Tables.users, ['user_id']),
  (
    Tables.observations,
    ['tag_id', 'project_id'],
    Tables.tags,
    ['tag_id', 'project_id'],
  ),
  // The one composite reference — see the note above. `session_id` stays
  // nullable and Postgres's default MATCH SIMPLE treats a partly-NULL
  // composite key as satisfied, so a session-less observation is unconstrained
  // exactly as it was before.
  (
    Tables.observations,
    ['session_id', 'project_id'],
    Tables.triangulationSessions,
    ['session_id', 'project_id'],
  ),
  // Task 11.7. Deliberately no reference to `Observations` from either
  // `observation_id` or `superseded_by_observation_id` — the app's schema.dart
  // gives the argument in full; the short version is that sync legitimately
  // delivers a mark before the observation it names, and a mark naming an
  // observation this server does not hold is inert rather than corrupt.
  (
    Tables.observationExclusions,
    ['project_id'],
    Tables.projects,
    ['project_id'],
  ),
  (Tables.observationExclusions, ['user_id'], Tables.users, ['user_id']),
  // Task 11.32. `Tag_Versions.tag_id` is a real reference: a version cannot
  // mean anything without the tag it versions, and the two are delivered to a
  // project by the same reachability, so this can never dangle in the way the
  // exclusion references above can. `Observations.tag_version_id` gets **no**
  // foreign key, for the reason the app's `schemaV9Statements` states at
  // length — sync can legitimately deliver a bearing before the version it
  // names, and a pasted record may name one this server will never hold.
  (
    Tables.tagVersions,
    ['tag_id', 'project_id'],
    Tables.tags,
    ['tag_id', 'project_id'],
  ),
  (Tables.nonDetections, ['project_id'], Tables.projects, ['project_id']),
  (Tables.nonDetections, ['user_id'], Tables.users, ['user_id']),
  (Tables.estimatedPositions, ['project_id'], Tables.projects, ['project_id']),
  (
    Tables.estimatedPositions,
    ['tag_id', 'project_id'],
    Tables.tags,
    ['tag_id', 'project_id'],
  ),
  (Tables.actualTagLocations, ['project_id'], Tables.projects, ['project_id']),
  (
    Tables.actualTagLocations,
    ['tag_id', 'project_id'],
    Tables.tags,
    ['tag_id', 'project_id'],
  ),
];

/// The constraint name for [fk]. Derived from the *first* column only, so it is
/// unchanged by task 10.35 widening `fk_observations_session_id` to two
/// columns — which matters, because the v6 migration has to drop the existing
/// constraint by the name the v1 bootstrap gave it.
String foreignKeyName((String, List<String>, String, List<String>) fk) =>
    'fk_${fk.$1}_${fk.$2.first}'.toLowerCase();

String alterAddForeignKey((String, List<String>, String, List<String>) fk) {
  final (table, columns, refTable, refColumns) = fk;
  return 'ALTER TABLE ${quoted(table)} '
      'ADD CONSTRAINT ${quoted(foreignKeyName(fk))} '
      'FOREIGN KEY (${columns.join(', ')}) '
      'REFERENCES ${quoted(refTable)}(${refColumns.join(', ')}) '
      'DEFERRABLE INITIALLY DEFERRED';
}

/// Indexes the server needs.
///
/// The `(project_id, server_seq)` pair on every project-scoped table is the
/// one the entire sync protocol rests on: every pull is "rows in this project
/// with `server_seq` greater than this cursor, in order." Without it each pull
/// is a full table scan, and pulls happen on every sync from every device.
List<String> createIndexes() {
  final statements = <String>[];
  for (final spec in tableSpecs) {
    final columns = spec.columnNames.toSet();
    final table = quoted(spec.name);
    if (columns.contains('project_id')) {
      statements.add(
        'CREATE INDEX ${quoted('idx_${spec.name}_project_seq'.toLowerCase())} '
        'ON $table (project_id, server_seq)',
      );
    } else {
      // `Users` and `User_Emails` are global (not project-scoped) but still
      // need a cursor-ordered scan for delta pulls. **`Tags` was on this
      // branch until task 11.219** and is now on the one above, which is the
      // whole of what copy-on-add bought the read filter.
      statements.add(
        'CREATE INDEX ${quoted('idx_${spec.name}_seq'.toLowerCase())} '
        'ON $table (server_seq)',
      );
    }
    // Partial index: skewed rows are meant to be rare, so indexing only the
    // non-null ones keeps this near-free while making the diagnostics
    // console's "show me the skewed rows" query (10.13) an index scan.
    statements.add(
      'CREATE INDEX ${quoted('idx_${spec.name}_skew'.toLowerCase())} '
      'ON $table (clock_skew_flag) WHERE clock_skew_flag IS NOT NULL',
    );
  }
  // Cross-device user dedup by normalized email, matching the app's index.
  statements.add(
    'CREATE INDEX ${quoted('idx_users_email')} ON ${quoted(Tables.users)} (email)',
  );
  statements.add(
    'CREATE INDEX ${quoted('idx_user_emails_email')} '
    'ON ${quoted(Tables.userEmails)} (email)',
  );
  // Task 11.32: the column every "what did this tag read" lookup runs.
  // Explicit here for the same reason the two email indexes are: it is a
  // lookup index on a non-key column, which the derivation above — which
  // only knows about `project_id` and `server_seq` — cannot infer.
  //
  // **It used to be described as the column pull narrows this table by.**
  // Task 11.219 made `Tag_Versions` project-scoped, so pull narrows it by
  // `project_id` like everything else and the derivation above builds that
  // index; this one is now purely the by-tag lookup.
  statements.add(
    'CREATE INDEX ${quoted('idx_tag_versions_tag')} '
    'ON ${quoted(Tables.tagVersions)} (tag_id)',
  );
  // Task 11.243: the two lookups `Deployments` exists to answer — "which
  // collars has this animal worn" and "who has worn this collar" — each on a
  // non-key column the derivation above cannot infer, like the two above.
  //
  // **They replace `idx_tags_individual`**, which task 11.240 added for the
  // first of those questions and which went with the column it indexed.
  statements.add(
    'CREATE INDEX ${quoted('idx_deployments_individual')} '
    'ON ${quoted(Tables.deployments)} (individual_id)',
  );
  statements.add(
    'CREATE INDEX ${quoted('idx_deployments_tag')} '
    'ON ${quoted(Tables.deployments)} (tag_id)',
  );
  return statements;
}

/// Every statement needed to build the server schema from empty, in order.
///
/// **Must include every standing invariant, not just what [tableSpecs] and
/// [createIndexes] derive generically.** A fresh bootstrap never replays
/// [serverMigrations] — it inserts [PostgresMigrations.targetVersion] into
/// `schema_migrations` directly and returns, on the premise that this
/// function already builds the *current* schema in one pass. That premise
/// held for task 10.35's rekeyed primary keys and task 11.7's new table,
/// because [tableSpecs] already describes both directly. It does **not**
/// hold for [schemaV8Statements]'s partial unique index, which
/// [createIndexes] has no way to derive — so it is appended here explicitly.
/// Its own `CREATE UNIQUE INDEX` is plain DDL with no ALTER-only assumption,
/// so replaying it here is safe.
///
/// Task 11.32's `Tag_Versions` is back in the derivable class — [tableSpecs]
/// describes the table and its `tag_id` foreign key is in [foreignKeys] — with
/// one exception, `idx_tag_versions_tag`, which is added inside
/// [createIndexes] rather than here because it is an ordinary lookup index and
/// belongs beside the other two of its kind.
List<String> schemaStatements() => [
  createSchemaMigrations,
  createSyncSeqCounter,
  seedSyncSeqCounter,
  // Tables in FK-safe order. With deferred constraints the order is not
  // strictly required, but it keeps the DDL readable and matches Tables.all.
  for (final spec in tableSpecs) createTableFor(spec),
  for (final fk in foreignKeys) alterAddForeignKey(fk),
  ...createIndexes(),
  ...schemaV8Statements(),
];

/// Schema v6 (task 10.35, **schema major 2**): re-key the six project-scoped
/// data tables to `(<id>, project_id)`.
///
/// **The server's first real migration.** Until now `PostgresMigrations` had a
/// single bootstrap statement list and threw on anything else, with a note that
/// from the next schema change onward it would need a migration per version.
/// This is that change.
///
/// Why the bump was worth making is argued in `TriTrack_Security_Model.md`
/// §4.13; the server-side effect is that `SyncService._findRow` — which builds
/// its predicate from `SyncTable.primaryKey` and therefore needs no edit —
/// stops being able to see a row in another project at all.
///
/// **Deliberately hardcoded rather than derived from [tableSpecs].** Generating
/// it would be shorter and would track the specs automatically, which is
/// exactly the problem: a shipped migration must describe the change *as it was
/// made*, and a spec-derived one silently becomes a different migration the
/// next time the specs move. This is the standing "never edit a shipped
/// migration" rule applied to a migration that has not shipped yet.
///
/// Order matters. The foreign key on `Observations.session_id` depends on
/// `Triangulation_Sessions`' primary key, so it is dropped before that key
/// changes and re-added afterwards in its widened, composite form. No data is
/// rewritten: `project_id` is already `NOT NULL` on all six tables, so every
/// row's new key is derived from what it already holds.
List<String> schemaV6Statements() {
  const sessionForeignKey = (
    Tables.observations,
    ['session_id', 'project_id'],
    Tables.triangulationSessions,
    ['session_id', 'project_id'],
  );

  // (table, new primary key) — mirrors `syncTables` at the moment of the bump.
  const rekeyed = <(String, List<String>)>[
    (Tables.projectMemberships, ['membership_id', 'project_id']),
    (Tables.triangulationSessions, ['session_id', 'project_id']),
    (Tables.observations, ['observation_id', 'project_id']),
    (Tables.nonDetections, ['non_detection_id', 'project_id']),
    (Tables.estimatedPositions, ['position_id', 'project_id']),
    (Tables.actualTagLocations, ['location_id', 'project_id']),
  ];

  return [
    'ALTER TABLE ${quoted(Tables.observations)} '
        'DROP CONSTRAINT ${quoted(foreignKeyName(sessionForeignKey))}',
    for (final (table, primaryKey) in rekeyed) ...[
      // Postgres names an unnamed primary key `<table>_pkey`, preserving the
      // case of the quoted identifier it was created under.
      'ALTER TABLE ${quoted(table)} DROP CONSTRAINT ${quoted('${table}_pkey')}',
      'ALTER TABLE ${quoted(table)} '
          'ADD PRIMARY KEY (${primaryKey.join(', ')})',
    ],
    alterAddForeignKey(sessionForeignKey),
  ];
}

/// Every server migration by the schema version it brings the database *to*.
///
/// Version 1 is absent on purpose: it is the whole-schema bootstrap in
/// [schemaStatements], which a fresh database runs instead of replaying
/// history. Versions 2–5 are absent because they predate the server, which was
/// built after them and has therefore only ever created their result directly.
const Map<int, List<String> Function()> serverMigrations = {
  6: schemaV6Statements,
  7: schemaV7Statements,
  8: schemaV8Statements,
  9: schemaV9Statements,
  10: schemaV10Statements,
  11: schemaV11Statements,
  12: schemaV12Statements,
  13: schemaV13Statements,
  14: schemaV14Statements,
  15: schemaV15Statements,
  16: schemaV16Statements,
  17: schemaV17Statements,
  18: schemaV18Statements,
  19: schemaV19Statements,
  20: schemaV20Statements,
};

/// **The tables schema v17 empties**, child before parent, so each `DELETE`
/// runs while its own references still resolve. Deferred constraints make the
/// order optional in fact; it is written out because a reader should be able
/// to see that it is safe without first knowing that.
///
/// Public so `postgres_migration_upgrade_test` can count the rows this
/// migration is about to destroy **against the same list the migration
/// uses**. A second copy in the test would be a hand-maintained list of what
/// the wipe covers, and the first thing it would go wrong about is a table
/// added to one and not the other — which is precisely the mistake this
/// project has a rule about.
const List<String> v17EmptiedTables = [
  Tables.observationExclusions,
  Tables.observations,
  Tables.triangulationSessions,
  Tables.nonDetections,
  Tables.estimatedPositions,
  Tables.actualTagLocations,
  Tables.tagVersions,
  Tables.tags,
  Tables.individuals,
];

/// Schema v17 (task 11.243, **schema major 5**): a tag is equipment, the link
/// is a dated row, **and this migration deletes data on purpose.**
///
/// `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` is the decision and the
/// app's `schemaV17Statements` in `lib/data/db/schema.dart` carries the same
/// argument. Michael is wiping (§9): the beta server holds development data
/// only, so `Tags` loses four columns and every table that names a tag is
/// emptied rather than a path being written to carry five rows across.
///
/// **What survives**: `Users`, `User_Emails`, `Projects`,
/// `Project_Memberships`. Signing in, the projects and the team are
/// untouched; the collars, the bearings and the animals are not.
///
/// ## Two differences from the app's version, both structural
///
/// **`DELETE` rather than `TRUNCATE`.** `TRUNCATE` would be faster and would
/// also reset nothing this schema depends on — but it takes an `ACCESS
/// EXCLUSIVE` lock on every named table at once and this runs inside the
/// migration transaction beside everything else. At this data volume the
/// difference is unmeasurable and the lock is not.
///
/// **`ALTER TABLE ... DROP COLUMN` rather than a rebuild.** Postgres can drop
/// a column and its dependent constraint in place, which SQLite cannot — so
/// there is no create-copy-drop-rename here and no column list to keep in
/// step. The foreign key `Tags.(individual_id, project_id)` goes with the
/// column it is on, automatically.
///
/// The last statement returns the census, which `PostgresMigrations.run`
/// prints. **A migration that deletes a row per existing row and prints
/// nothing cannot be told from one that deleted none**, and here the two
/// outcomes are as far apart as they get.
List<String> schemaV17Statements() {
  const deployments = Tables.deployments;
  final before = v17EmptiedTables
      .map((t) => '(SELECT count(*) FROM ${quoted(t)})')
      .join(' + ');
  return [
    // 1. The census, taken **before** anything is deleted and held in a
    //    temporary table, because the numbers are the whole point and after
    //    the deletes there is nothing left to count. `ON COMMIT DROP`: it
    //    lives exactly as long as this migration's transaction, the same way
    //    v14's derivation table does.
    'CREATE TEMP TABLE _v17_census ON COMMIT DROP AS SELECT $before AS rows',

    // 2. Everything that names a tag, and the animals 11.240's backfill
    //    fabricated one-per-collar.
    for (final table in v17EmptiedTables) 'DELETE FROM ${quoted(table)}',

    // 3. **Discharge the deferred foreign-key checks the deletes queued,
    //    before touching a column.** Every constraint in this schema is
    //    `DEFERRABLE INITIALLY DEFERRED` (see [foreignKeys]) for a reason
    //    that has nothing to do with this migration: a sync push arrives as
    //    a batch whose rows reference each other, and per-statement checks
    //    would make correctness depend on iteration order.
    //
    //    The consequence here is that after the deletes above, Postgres is
    //    holding an unfired trigger event per affected row, and
    //    `ALTER TABLE ... DROP COLUMN` on a table with pending events fails
    //    with **"cannot ALTER TABLE because it has pending trigger
    //    events"**. This line makes them fire now, while the deletes are
    //    still provably consistent, so the ALTERs below have a clean table.
    //
    //    **Found by `postgres_migration_upgrade_test`'s wipe group on a
    //    populated database, not by reading the DDL** — the statements are
    //    each individually correct and only their combination in one
    //    transaction is not, which is exactly what an empty-database test
    //    cannot see.
    'SET CONSTRAINTS ALL IMMEDIATE',

    // 4. The four columns that made a `Tags` row a deployment. Dropping
    //    `individual_id` takes `fk_tags_individual_id` with it.
    for (final column in [
      'date_put_on',
      'date_removed',
      'capture_date',
      'individual_id',
    ])
      'ALTER TABLE ${quoted(Tables.tags)} DROP COLUMN $column',
    'DROP INDEX IF EXISTS ${quoted('idx_tags_individual')}',

    // 5. The dated link. Written out rather than derived from `tableSpecs`
    //    for the reason `schemaV6Statements` gives at length: a shipped
    //    migration must describe the change *as it was made*, and a
    //    spec-derived one silently becomes a different migration the next
    //    time the specs move.
    //
    //    **No `server_seq` backfill**, unlike v16's: there are no rows to
    //    give one to. The table is created empty and every row that ever
    //    lands in it arrives through an ordinary push, which assigns one.
    'CREATE TABLE ${quoted(deployments)} ('
        'deployment_id TEXT NOT NULL, '
        'project_id TEXT NOT NULL, '
        'tag_id TEXT NOT NULL, '
        'individual_id TEXT NOT NULL, '
        'attached_date TEXT, '
        'removed_date TEXT, '
        'notes TEXT, '
        'created_at TEXT NOT NULL, '
        'updated_at TEXT NOT NULL, '
        'deleted_at TEXT, '
        'revision BIGINT NOT NULL, '
        'last_modified_by TEXT, '
        'origin_device_id TEXT, '
        'server_seq BIGINT, '
        'received_at TIMESTAMPTZ NOT NULL DEFAULT now(), '
        'clock_skew_flag TEXT, '
        'PRIMARY KEY (deployment_id, project_id))',
    alterAddForeignKey((
      deployments,
      const ['project_id'],
      Tables.projects,
      const ['project_id'],
    )),
    alterAddForeignKey((
      deployments,
      const ['tag_id', 'project_id'],
      Tables.tags,
      const ['tag_id', 'project_id'],
    )),
    alterAddForeignKey((
      deployments,
      const ['individual_id', 'project_id'],
      Tables.individuals,
      const ['individual_id', 'project_id'],
    )),
    'CREATE INDEX ${quoted('idx_${deployments}_project_seq'.toLowerCase())} '
        'ON ${quoted(deployments)} (project_id, server_seq)',
    'CREATE INDEX ${quoted('idx_${deployments}_skew'.toLowerCase())} '
        'ON ${quoted(deployments)} (clock_skew_flag) '
        'WHERE clock_skew_flag IS NOT NULL',
    'CREATE INDEX ${quoted('idx_deployments_individual')} '
        'ON ${quoted(deployments)} (individual_id)',
    'CREATE INDEX ${quoted('idx_deployments_tag')} '
        'ON ${quoted(deployments)} (tag_id)',

    // 6. The finding. Returned rather than logged from Dart, so it lands
    //    where every other migration's does.
    "SELECT format('tags are equipment now and the tag/animal link is a "
        'dated Deployments row. THIS MIGRATION DELETED DATA ON PURPOSE '
        '(ANIMALS_AND_DEPLOYMENTS_DESIGN.md section 9): %s row(s) destroyed '
        'across collars, bearings, sessions, estimates, truth points, '
        'no-signal entries and animals. Projects, memberships and sign-in '
        "are untouched.', (SELECT rows FROM _v17_census))",
  ];
}

/// Schema v7 (task 11.7): add `Observation_Exclusions`.
///
/// Purely additive — a new table, its two foreign keys and its indexes — so
/// [schemaMajorVersion] stays at 2 and a server on v7 still syncs with a
/// client on v6, which simply preserves the columns it does not recognize.
///
/// Hardcoded rather than derived from [tableSpecs], for the reason
/// [schemaV6Statements] gives at length: a shipped migration must describe the
/// change as it was made, and a spec-derived one silently becomes a different
/// migration the next time the specs move.
List<String> schemaV7Statements() {
  const table = Tables.observationExclusions;
  return [
    'CREATE TABLE ${quoted(table)} ('
        'exclusion_id TEXT NOT NULL, '
        'project_id TEXT NOT NULL, '
        'observation_id TEXT NOT NULL, '
        'user_id TEXT NOT NULL, '
        'kind TEXT NOT NULL, '
        'superseded_by_observation_id TEXT, '
        'reason TEXT, '
        'created_at TEXT NOT NULL, '
        'updated_at TEXT NOT NULL, '
        'deleted_at TEXT, '
        'revision BIGINT NOT NULL, '
        'last_modified_by TEXT, '
        'origin_device_id TEXT, '
        'server_seq BIGINT, '
        'received_at TIMESTAMPTZ NOT NULL DEFAULT now(), '
        'clock_skew_flag TEXT, '
        'PRIMARY KEY (exclusion_id, project_id))',
    alterAddForeignKey((
      table,
      const ['project_id'],
      Tables.projects,
      const ['project_id'],
    )),
    alterAddForeignKey((
      table,
      const ['user_id'],
      Tables.users,
      const ['user_id'],
    )),
    'CREATE INDEX ${quoted('idx_${table}_project_seq'.toLowerCase())} '
        'ON ${quoted(table)} (project_id, server_seq)',
    'CREATE INDEX ${quoted('idx_${table}_skew'.toLowerCase())} '
        'ON ${quoted(table)} (clock_skew_flag) WHERE clock_skew_flag IS NOT NULL',
  ];
}

/// Schema v8 (task 11.10): a database constraint behind the one-open-
/// membership-per-project rule.
///
/// **The rule was code-only.** `JoinService.approve` reads "does this person
/// already hold an open membership" and then, further down the same
/// transaction, writes one — and a read-then-write has a gap: two invitations
/// for the same person accepted at the same instant can both pass the read
/// before either writes, leaving two open rows for one person in one project.
/// `Project_Memberships.findForUser` (both here and on the app) takes the
/// first row it finds, so that would make role lookup arbitrary. The read's
/// refusal (`RedemptionFailure.alreadyMember`) is kept — it is what turns the
/// race into a message a person can read instead of a raw constraint error —
/// and this index is the backstop that makes the race actually impossible
/// rather than merely unlikely.
///
/// A **partial** unique index, not a plain one: a person legitimately holds
/// several *closed* (ended) rows for the same project across a rejoin history
/// (task 11.2) — only one *open* row is the rule. Open is
/// `end_date IS NULL AND deleted_at IS NULL`, the same definition
/// `isOpenOwnerMembership` in `package:tritrack_sync` uses for the ownership
/// question (this index covers every role, not just `owner`). Mirrors the
/// app's `schemaV8Statements` in `lib/data/db/schema.dart` — either side can
/// be the one that accepts an invitation, so both must hold the invariant.
///
/// Purely additive, so [schemaMajorVersion] stays at 2.
List<String> schemaV8Statements() => [
  'CREATE UNIQUE INDEX ${quoted('idx_memberships_one_open')} '
      'ON ${quoted(Tables.projectMemberships)} (project_id, user_id) '
      'WHERE end_date IS NULL AND deleted_at IS NULL',
];

/// Schema v9 (task 11.32): add `Tag_Versions`, and `tag_version_id` to
/// `Observations`.
///
/// Purely additive — a new global table, its one foreign key, its indexes, and
/// one nullable column — so [schemaMajorVersion] stays at 2 and a server on v9
/// still syncs with a client on v8, which preserves the column it does not
/// recognize.
///
/// The column set mirrors the app's `schemaV9Statements` exactly, and is
/// **hardcoded rather than derived from [tableSpecs]** for the reason
/// [schemaV7Statements] gives: a shipped migration must describe the change as
/// it was made. `postgres_schema_test.dart` is what checks the two arrive at
/// the same shape.
///
/// **No backfill of `tag_version_id`, and no invented version for an existing
/// tag.** Both are stated in the app's migration and both matter more here:
/// this database holds other people's records, and writing a value into a
/// bearing somebody else took would be inventing measurement context on their
/// behalf.
List<String> schemaV9Statements() {
  const table = Tables.tagVersions;
  return [
    'CREATE TABLE ${quoted(table)} ('
        'tag_version_id TEXT NOT NULL, '
        'tag_id TEXT NOT NULL, '
        'effective_from TEXT NOT NULL, '
        'frequency_mhz DOUBLE PRECISION NOT NULL, '
        'pulse_rate DOUBLE PRECISION, '
        'pulse_pattern TEXT, '
        'tag_name TEXT NOT NULL, '
        'created_at TEXT NOT NULL, '
        'updated_at TEXT NOT NULL, '
        'deleted_at TEXT, '
        'revision BIGINT NOT NULL, '
        'last_modified_by TEXT, '
        'origin_device_id TEXT, '
        'server_seq BIGINT, '
        'received_at TIMESTAMPTZ NOT NULL DEFAULT now(), '
        'clock_skew_flag TEXT, '
        'PRIMARY KEY (tag_version_id))',
    alterAddForeignKey((
      table,
      const ['tag_id'],
      Tables.tags,
      const ['tag_id'],
    )),
    // Global table: cursor-ordered scan on `server_seq` alone, matching what
    // `createIndexes()` builds for `Users` and `Tags` on a fresh bootstrap.
    'CREATE INDEX ${quoted('idx_${table}_seq'.toLowerCase())} '
        'ON ${quoted(table)} (server_seq)',
    'CREATE INDEX ${quoted('idx_${table}_skew'.toLowerCase())} '
        'ON ${quoted(table)} (clock_skew_flag) WHERE clock_skew_flag IS NOT NULL',
    // The column pull narrows this table by (`SyncTable.globalScope`), and the
    // one `Tag_Versions`' own reads look up.
    'CREATE INDEX ${quoted('idx_${table}_tag'.toLowerCase())} '
        'ON ${quoted(table)} (tag_id)',
    'ALTER TABLE ${quoted(Tables.observations)} ADD COLUMN tag_version_id TEXT',
  ];
}

/// Schema v10 (task 11.33): `found_kind` and `tag_version_id` on
/// `Actual_Tag_Locations`.
///
/// Mirrors the app's `schemaV10Statements` in `lib/data/db/schema.dart`, which
/// carries the full argument for both columns and for the two tables that
/// deliberately record no tag version. The short version: `found_kind` says
/// whether the animal, the collar, or both were found, because only "both"
/// validates the triangulation of a live collared animal; `tag_version_id`
/// says what the tag read at the time, so an export made after a rename can
/// still be matched to the animal it describes.
///
/// Purely additive — two nullable columns — so [schemaMajorVersion] stays at 2
/// and a server on v10 still syncs with a client on v9, which preserves the
/// columns it does not recognise.
///
/// **No backfill, and no foreign key on `tag_version_id`.** Both are stated in
/// the app's migration and both matter more here: this database holds other
/// people's records, so writing a value into a point somebody else took would
/// be inventing field context on their behalf, and a point can legitimately
/// arrive before the `Tag_Versions` row it names.
List<String> schemaV10Statements() => [
  'ALTER TABLE ${quoted(Tables.actualTagLocations)} '
      'ADD COLUMN found_kind TEXT',
  'ALTER TABLE ${quoted(Tables.actualTagLocations)} '
      'ADD COLUMN tag_version_id TEXT',
];

/// Schema v11 (task 11.93): `user_id` and `position_source` on
/// `Actual_Tag_Locations`.
///
/// Mirrors the app's `schemaV11Statements` in `lib/data/db/schema.dart`, which
/// carries the full argument. The short version: `user_id` records **who
/// walked in and found the collar**, which `last_modified_by` never said and
/// was being read as though it did; `position_source` says whether the
/// coordinate is a GPS fix, a hand-placed pin, or **a fix somebody later
/// nudged by hand**, which became a distinguishable third thing the moment
/// task 11.93 made the position editable.
///
/// Purely additive — two nullable columns — so [schemaMajorVersion] stays at 2
/// and a server on v11 still syncs with a client on v10, which preserves the
/// columns it does not recognise.
///
/// **No backfill.** Stated in the app's migration and it matters more here:
/// this database holds other people's records, so naming an author on a point
/// somebody else took would be inventing field provenance on their behalf.
/// NULL means "not recorded" and every screen says so in those words.
///
/// **No foreign key on `user_id`**, matching the app for the reason its
/// migration gives, and one this side adds: `RowAuthorizer._authorizeNaming`
/// already refuses any `user_id` here but the authenticated caller's own —
/// see [SyncTable.vouchesForAForeignNameIn], which task 11.93 narrowed to make
/// that true of an identity column on an `anyUser` table.
List<String> schemaV11Statements() => [
  'ALTER TABLE ${quoted(Tables.actualTagLocations)} '
      'ADD COLUMN user_id TEXT',
  'ALTER TABLE ${quoted(Tables.actualTagLocations)} '
      'ADD COLUMN position_source TEXT',
];

/// Schema v12 (task 11.187): the five pulse-mode columns on `Tags` and
/// `Tag_Versions`, and `pulse_mode` on `Observations`.
///
/// Mirrors the app's `schemaV12Statements` in `lib/data/db/schema.dart`, which
/// carries the full argument. The short version: a tag's pulse modes are named
/// and rated by the person who entered the tag rather than being two words
/// baked into the schema, an observation records **which mode** it was heard on
/// as a slot number, and slot 1's rate stays in the column already called
/// `pulse_rate` so that no stored value moves and no `Tag_Versions` history
/// changes meaning.
///
/// Purely additive — eleven nullable columns — so [schemaMajorVersion] stays at
/// 2 and a server on v12 still syncs with a client on v11, which preserves the
/// columns it does not recognise.
///
/// **Every column is nullable, including `pulse_mode_1_name`, and on this side
/// that is the load-bearing half of the decision.** A `NOT NULL` column added
/// here with no default is refused by Postgres the moment a v11 client pushes a
/// `Tags` row — a client that cannot know the column exists. That would turn a
/// *minor* schema difference into a device that cannot sync, which is precisely
/// what the major/minor split exists to prevent. A null slot-1 name reads as
/// the default mode name and never as "this tag has no modes".
///
/// **The two `UPDATE`s write names and no rates**, and the asymmetry is the
/// point. Naming the two modes every tag had under v11 is transcription of what
/// that build offered; writing a mortality *rate* would be a measurement nobody
/// took, and this database holds other people's records. Michael's 120 bpm
/// default belongs to a tag being created, not to a tag being upgraded.
///
/// **`Tag_Versions` is altered here and rebuilt in the app, and that difference
/// is deliberate.** The app's `schema_matches_shared_spec_test.dart` compares
/// SQLite's *column order* against the shared spec, whose `Tag_Versions` list is
/// derived from `Tags`; appending cannot produce the derived order, so the app
/// rebuilds the table. This side's guard checks that every declared column is
/// present with the right type and does not compare ordinal position, so a
/// rebuild here would buy nothing and would ask a live beta server holding a
/// field season to copy a table for cosmetic reasons.
List<String> schemaV12Statements() => [
  for (final column in ['pulse_mode_1_name', 'pulse_mode_2_name'])
    'ALTER TABLE ${quoted(Tables.tags)} ADD COLUMN $column TEXT',
  'ALTER TABLE ${quoted(Tables.tags)} '
      'ADD COLUMN pulse_mode_2_rate_bpm DOUBLE PRECISION',
  'ALTER TABLE ${quoted(Tables.tags)} ADD COLUMN pulse_mode_3_name TEXT',
  'ALTER TABLE ${quoted(Tables.tags)} '
      'ADD COLUMN pulse_mode_3_rate_bpm DOUBLE PRECISION',
  for (final column in ['pulse_mode_1_name', 'pulse_mode_2_name'])
    'ALTER TABLE ${quoted(Tables.tagVersions)} ADD COLUMN $column TEXT',
  'ALTER TABLE ${quoted(Tables.tagVersions)} '
      'ADD COLUMN pulse_mode_2_rate_bpm DOUBLE PRECISION',
  'ALTER TABLE ${quoted(Tables.tagVersions)} ADD COLUMN pulse_mode_3_name TEXT',
  'ALTER TABLE ${quoted(Tables.tagVersions)} '
      'ADD COLUMN pulse_mode_3_rate_bpm DOUBLE PRECISION',
  for (final table in [Tables.tags, Tables.tagVersions])
    'UPDATE ${quoted(table)} SET '
        "pulse_mode_1_name = '${defaultPulseModeNames[0]}', "
        "pulse_mode_2_name = '${defaultPulseModeNames[1]}'",
  'ALTER TABLE ${quoted(Tables.observations)} ADD COLUMN pulse_mode BIGINT',
];

/// Schema v13 (task 11.193): `signal_irregular` on `Observations` — one bit
/// saying the signal itself sounded wrong.
///
/// Mirrors the app's `schemaV13Statements` in `lib/data/db/schema.dart`, which
/// carries the argument. `BIGINT` because [postgresType] maps the shared
/// [ColumnType.integer] to it, and the shared spec is what both sides are
/// checked against; a `BOOLEAN` here would be truer to the value and would put
/// this column's type outside that derivation, which is the drift the shared
/// spec exists to prevent.
///
/// **Nullable, with no default, and no `UPDATE` behind it.** A default of 0
/// would tell every row already on a beta server that somebody listened and
/// heard nothing wrong — a claim none of those observers made. Additive and
/// nullable also means a v12 client, which cannot know the column exists, still
/// pushes `Observations` rows this server accepts.
List<String> schemaV13Statements() => [
  'ALTER TABLE ${quoted(Tables.observations)} '
      'ADD COLUMN signal_irregular BIGINT',
];

/// Schema v14 (task 11.219, **schema major 3**): a tag belongs to one
/// project, and adding a tag to a project copies it.
///
/// The design is `CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md`; the argument for
/// spending the second major bump this project has ever spent is on
/// `schemaMajorVersion`. Mirrors the app's `schemaV14TableStatements` and
/// `TagScopeMigration`.
///
/// ## Why there is no fork here, and why that is a decision rather than an
/// omission
///
/// §3.4 leaves the server's data a choice: migrate it, or drop and recreate
/// the development database. **Neither is needed to make this correct: the
/// `DO` block below censuses every tag's links and every project that names
/// it at run time, so it is correct whether or not any server has ever
/// actually held a tag in two projects.** (A weaker, historical reason to
/// expect the same thing: `RowAuthorizer._tagIsClaimedElsewhere` has refused
/// a `Project_Tags` insert naming a tag another project already references
/// for as long as tags have been shareable.)
///
/// It is still written to **fail rather than guess**, and the refusal is the
/// first statement, by name, before anything moves. **Task 11.222 found that
/// this paragraph used to describe a refusal the statements did not make.**
/// The scoping `UPDATE` carried a `LIMIT 1`, so a tag linked to two projects
/// was not "left ambiguous" for the `NOT NULL` step to catch — it was placed
/// in whichever project the planner returned first, and the other project's
/// link was dropped with `Project_Tags`. If that other project held a
/// bearing naming the tag, the foreign-key step aborted the run with an
/// error naming a constraint; if it held only the link, the run completed
/// and the collar silently vanished from that project's list. Neither is a
/// refusal. The `DO` block below is: it counts every tag's links and every
/// project that names it, and raises **one message listing every offender**
/// so the person reading the server log knows which collars to look at
/// rather than which column complained. The `LIMIT 1` is gone, so if that
/// census were ever wrong the scalar subquery itself refuses (SQLSTATE
/// 21000) rather than guessing — the later `NOT NULL` and foreign-key steps
/// are backstops now, not the refusal. A half-migrated sync server is worse
/// than an unavailable one (§1.5, fail closed), and this is the version of
/// that rule that applies to data rather than to code.
///
/// ## A tag linked to no project is deleted, not refused — and why that is
/// different from a tag linked to two
///
/// **Task 11.227.** The first real database this ran against — the beta
/// server, measured 2026-09-11 — held five collars: four linked to one
/// project each and **one linked to none**, and step 0 as task 11.222 wrote
/// it refused on `n <> 1`, which includes zero. That refusal was correct
/// for what it knew. The two cases are not the same decision, though:
///
/// - **A tag linked to two projects is a decision about the scientific
///   record.** Which project keeps the original identifier, and whether the
///   other gets a copy, changes what a bearing's `tag_id` means in an export
///   — the app's `TagScopeMigration` forks it, and on a server holding other
///   people's records that is a choice for a person, not a migration. **It
///   stays an unconditional refusal.**
/// - **A tag linked to no project and named by nothing is not.** Nothing
///   references it — that is what made it an orphan — so nothing dangles
///   when it goes, and nothing on any device will ever ask for it: sync is
///   per-project on both sides (`TAG_COPY_ON_ADD_DESIGN.md` §1.5), so an
///   unlinked tag can neither be pushed nor pulled. The app's answer for the
///   same row (§3.3) is "move it to the device's tag library and delete it
///   from `Tags`"; the server has no library, so its equivalent is the
///   delete alone. **Deleted, counted, and named in the log, zero included.**
/// - **A tag linked to no project but named by something is still refused**,
///   and the message says which tables name it and how many rows. Deleting
///   it would leave those rows dangling, and deciding what they mean is
///   again a person's call.
///
/// **"Named by something" is derived from the catalog, not from a list.**
/// The census query task 11.222 gave Michael reads four tables, and
/// `Tag_Versions` is not one of them — a tag with a version chain and no
/// project is a different animal from a bare row, and a hand-kept list of
/// referencing tables is exactly how it would go unchecked. So the `DO`
/// block asks `pg_constraint` which tables hold a foreign key into
/// `Tags(tag_id)` at the moment it runs, and probes every one of them. A
/// column naming a tag *without* a foreign key — `Non_Detections`'
/// `tag_ids_listened_for` — is by §5.9(b)'s standing decision not a
/// reference, and the assertion enforcing that
/// (`assertSealedColumnsFeedNoReachability`) is what keeps this derivation
/// honest. **The derivation refuses an empty result**: a v13 database that
/// reports no foreign key into `Tags` is one this block cannot reason
/// about, and a search that finds nothing must not read as "nothing names
/// it".
///
/// `server/test/schema/postgres_migration_upgrade_test.dart` runs this
/// against a populated **v11** database — the beta server's real shape,
/// through v12 and v13 — with a fixture built from that server's census:
/// the harmless case, the empty case, the orphan deleted and counted, and
/// each refusal, checking the database is byte-identical after a refusal.
///
/// ## What happens to `Project_Tags`
///
/// **Dropped.** On the app it stays as the durable record of what the
/// migration did (§3.5) and because an old archive still carries its rows;
/// neither reason applies here. The server holds no archives, and its copy of
/// the links is reconstructible from the tags themselves. Dropping it is also
/// what lets `Tags` be re-keyed at all — the table's foreign key into
/// `Tags(tag_id)` would otherwise have to be dropped and could not be
/// re-added. **It is dropped the moment the scoping `UPDATE` has read it and
/// before the re-key**; see step 4 for the ordering defect task 11.222 found
/// there.
List<String> schemaV14Statements() {
  // The five references into `Tags` that widen from `(tag_id)` to
  // `(tag_id, project_id)`. Written out rather than derived from
  // [foreignKeys], for the reason [schemaV6Statements] gives at length: a
  // shipped migration must describe the change as it was made.
  const widened = <(String, List<String>, String, List<String>)>[
    (
      Tables.triangulationSessions,
      ['tag_id', 'project_id'],
      Tables.tags,
      ['tag_id', 'project_id'],
    ),
    (
      Tables.observations,
      ['tag_id', 'project_id'],
      Tables.tags,
      ['tag_id', 'project_id'],
    ),
    (
      Tables.tagVersions,
      ['tag_id', 'project_id'],
      Tables.tags,
      ['tag_id', 'project_id'],
    ),
    (
      Tables.estimatedPositions,
      ['tag_id', 'project_id'],
      Tables.tags,
      ['tag_id', 'project_id'],
    ),
    (
      Tables.actualTagLocations,
      ['tag_id', 'project_id'],
      Tables.tags,
      ['tag_id', 'project_id'],
    ),
  ];

  // The four v13 tables that name a tag and carry a project. `Tag_Versions`
  // is not one of them: at v13 it has no `project_id`, and it is scoped below
  // *from* its tag rather than checked against one.
  const tagNamingTables = [
    Tables.observations,
    Tables.triangulationSessions,
    Tables.estimatedPositions,
    Tables.actualTagLocations,
  ];
  final references = [
    for (final table in tagNamingTables)
      'SELECT tag_id, project_id FROM ${quoted(table)}',
  ].join(' UNION ');

  // A table's OID, looked up through `search_path` the same way every
  // unqualified table name in this migration is — so the derivation in step
  // 0 reads the same schema the statements around it act on.
  String regclassOf(String table) => "'${quoted(table)}'::regclass";

  // The one place a tag is linked to a project on a v13 database. Shared by
  // step 0's census and the deletion in step 0b, so the two cannot disagree
  // about what "linked to no project" means.
  final unlinked =
      'NOT EXISTS (SELECT 1 FROM ${quoted(Tables.projectTags)} pt '
      'WHERE pt.tag_id = t.tag_id)';

  return [
    // 0. Refuse, by name, before anything moves. Three ways a tag can be
    //    one the steps below cannot place: it is linked to several projects;
    //    it is linked to one and a row in *another* project names it; or it
    //    is linked to none and something still names it. All are listed in
    //    one message. Nothing has been altered when this raises, and
    //    `PostgresMigrations.run` rolls the version back, so a refused
    //    server is a v13 server, not a half-migrated one.
    //
    //    **A tag linked to none and named by nothing is not an offender** —
    //    step 0b deletes it, and the doc comment above says why that is a
    //    different decision from a tag linked to two. "Named by nothing" is
    //    derived here from every foreign key into `Tags(tag_id)` that the
    //    catalog holds when this runs, `Project_Tags` excepted (a tag with
    //    no link is the thing being tested, not a reference to it). The
    //    derivation refuses an empty result rather than concluding that
    //    nothing names anything.
    'DO \$\$ '
        'DECLARE '
        'offenders TEXT; '
        'reference_count INT; '
        'orphan RECORD; '
        'ref RECORD; '
        'hits BIGINT; '
        'named_by TEXT; '
        'BEGIN '
        'WITH links AS ('
        'SELECT t.tag_id, count(DISTINCT pt.project_id) AS n '
        'FROM ${quoted(Tables.tags)} t '
        'LEFT JOIN ${quoted(Tables.projectTags)} pt ON pt.tag_id = t.tag_id '
        'GROUP BY t.tag_id), '
        'strays AS ('
        'SELECT r.tag_id, r.project_id FROM ($references) r '
        'WHERE NOT EXISTS (SELECT 1 FROM ${quoted(Tables.projectTags)} pt '
        'WHERE pt.tag_id = r.tag_id AND pt.project_id = r.project_id)) '
        "SELECT string_agg(line, '; ' ORDER BY line) INTO offenders FROM ("
        "SELECT format('tag %s is linked to %s projects', tag_id, n) AS line "
        'FROM links WHERE n >= 2 '
        'UNION ALL '
        "SELECT format('tag %s is named by rows in project %s, which it is "
        "not linked to', tag_id, project_id) FROM strays) lines; "
        // Every (table, column) holding a foreign key into `Tags(tag_id)`,
        // read from the catalog. `ON COMMIT DROP` because the migration runs
        // inside one transaction and nothing after this block needs it.
        'CREATE TEMP TABLE schema_v14_tag_references ON COMMIT DROP AS '
        'SELECT c.conrelid::regclass::text AS tbl, a.attname AS col '
        'FROM pg_constraint c '
        'CROSS JOIN LATERAL unnest(c.conkey, c.confkey) '
        'AS k(local_attnum, ref_attnum) '
        'JOIN pg_attribute a '
        'ON a.attrelid = c.conrelid AND a.attnum = k.local_attnum '
        'JOIN pg_attribute ra '
        'ON ra.attrelid = c.confrelid AND ra.attnum = k.ref_attnum '
        "WHERE c.contype = 'f' "
        'AND c.confrelid = ${regclassOf(Tables.tags)} '
        "AND ra.attname = 'tag_id' "
        'AND c.conrelid <> ${regclassOf(Tables.projectTags)}; '
        'SELECT count(*) INTO reference_count FROM schema_v14_tag_references; '
        'IF reference_count = 0 THEN '
        "RAISE EXCEPTION 'schema v14 refused to run: the catalog reports no "
        'foreign key into ${quoted(Tables.tags)} other than '
        '${quoted(Tables.projectTags)}, which is not true of any v13 '
        'database, so whether a tag linked to no project is still named by '
        "something cannot be decided. The database was left as it was.'; "
        'END IF; '
        'FOR orphan IN '
        'SELECT t.tag_id FROM ${quoted(Tables.tags)} t WHERE $unlinked '
        'ORDER BY t.tag_id '
        'LOOP '
        'named_by := NULL; '
        'FOR ref IN '
        'SELECT tbl, col FROM schema_v14_tag_references ORDER BY tbl, col '
        'LOOP '
        r"EXECUTE format('SELECT count(*) FROM %s WHERE %I = $1', "
        'ref.tbl, ref.col) INTO hits USING orphan.tag_id; '
        'IF hits > 0 THEN '
        "named_by := concat_ws(', ', named_by, "
        "format('%s (%s rows)', ref.tbl, hits)); "
        'END IF; '
        'END LOOP; '
        'IF named_by IS NOT NULL THEN '
        "offenders := concat_ws('; ', offenders, "
        "format('tag %s is linked to no project but is still named by %s, "
        "so it was not deleted', orphan.tag_id, named_by)); "
        'END IF; '
        'END LOOP; '
        'IF offenders IS NOT NULL THEN '
        "RAISE EXCEPTION 'schema v14 refused to run: every tag must belong "
        "to exactly one project, and the database was left as it was. %', "
        'offenders; '
        'END IF; '
        'END \$\$',
    // 0b. Delete every tag linked to no project. Step 0 has just refused if
    //     any of them is still named by a row somewhere, so what this
    //     predicate matches is by construction a row nothing references —
    //     and if step 0 were ever wrong about that, a foreign key into
    //     `Tags` refuses the delete rather than letting a row dangle.
    //
    //     **The foreign keys are made immediate first, and that is not
    //     optional.** Every reference into `Tags` is `DEFERRABLE INITIALLY
    //     DEFERRED`, so a delete on the referenced side queues its check
    //     for commit — and Postgres refuses to `ALTER TABLE` a table with
    //     a check still queued against it (SQLSTATE 55006, "pending trigger
    //     events"), which is exactly what steps 1 and 2 do next. The first
    //     run of the census fixture in
    //     `postgres_migration_upgrade_test.dart` found that. Immediate
    //     checks run at the end of this statement instead, so the backstop
    //     above fires here, by name, and nothing is left pending for the
    //     DDL to trip over.
    //
    //     **This statement returns a row, and that is the point**:
    //     `PostgresMigrations.run` prints every row a migration statement
    //     returns, so the count and the ids land in the server's startup
    //     log, and a run that deletes nothing prints zero rather than
    //     nothing.
    'SET CONSTRAINTS ALL IMMEDIATE',
    'WITH deleted AS ('
        'DELETE FROM ${quoted(Tables.tags)} t WHERE $unlinked '
        'RETURNING tag_id) '
        "SELECT format('deleted %s tag row(s) linked to no project and named "
        "by nothing%s', count(*), "
        "coalesce(': ' || string_agg(tag_id, ', ' ORDER BY tag_id), '')) "
        'FROM deleted',
    // 1. Every reference into `Tags` comes off before its key changes shape.
    //    Postgres names these from the first column only ([foreignKeyName]),
    //    so the name is the one the v1 bootstrap gave.
    for (final fk in widened)
      'ALTER TABLE ${quoted(fk.$1)} '
          'DROP CONSTRAINT ${quoted(foreignKeyName(fk))}',
    // 2. The four new columns, nullable for now so the UPDATEs can fill
    //    them.
    'ALTER TABLE ${quoted(Tables.tags)} ADD COLUMN project_id TEXT',
    'ALTER TABLE ${quoted(Tables.tagVersions)} ADD COLUMN project_id TEXT',
    'ALTER TABLE ${quoted(Tables.tags)} ADD COLUMN lineage_id TEXT',
    'ALTER TABLE ${quoted(Tables.tags)} ADD COLUMN copied_at TEXT',
    // 3. Scope every tag to the one project that holds it. Step 0 has just
    //    proved there is exactly one, so the scalar subquery below always
    //    finds one row. **No `LIMIT 1`, deliberately**: with it, a tag in
    //    two projects was placed in one of them rather than refused (task
    //    11.222, and the doc comment above). Without it, a tag in two
    //    projects that step 0 somehow missed makes Postgres refuse the
    //    UPDATE outright (SQLSTATE 21000, "more than one row returned by a
    //    subquery"), and a tag in none — which step 0b has already deleted
    //    — would leave NULL for step 5 to refuse.
    'UPDATE ${quoted(Tables.tags)} t SET project_id = ('
        'SELECT pt.project_id FROM ${quoted(Tables.projectTags)} pt '
        'WHERE pt.tag_id = t.tag_id)',
    // A tag's own id is its lineage: already unique, already unguessable,
    // and true — nobody copied it. `copied_at` stays NULL for the same
    // reason the app's migration leaves it NULL: a tag that was always in
    // one project was not copied, and a date invented here would be a claim
    // about a past nobody observed.
    'UPDATE ${quoted(Tables.tags)} SET lineage_id = tag_id',
    'UPDATE ${quoted(Tables.tagVersions)} v SET project_id = ('
        'SELECT t.project_id FROM ${quoted(Tables.tags)} t '
        'WHERE t.tag_id = v.tag_id)',
    // 4. `Project_Tags` retires, and its two foreign keys with it. **This
    //    has to come before the re-key, and until task 11.222 it came
    //    after.** Its reference into `Tags(tag_id)` depends on `Tags_pkey`,
    //    so step 6's `DROP CONSTRAINT` refused with SQLSTATE 2BP01 on
    //    *every* v13 database, empty ones included — and nothing had ever
    //    run it against one, because a fresh bootstrap skips this list.
    //    The migration test's oracle group is what found it. Step 3 has
    //    finished reading the table by now, which is the only reason it
    //    was still here.
    'DROP TABLE ${quoted(Tables.projectTags)}',
    // 5. The columns become NOT NULL. A backstop now — step 0 refuses by
    //    name — but still the step that refuses a row step 3 left NULL.
    'ALTER TABLE ${quoted(Tables.tags)} ALTER COLUMN project_id SET NOT NULL',
    'ALTER TABLE ${quoted(Tables.tags)} ALTER COLUMN lineage_id SET NOT NULL',
    'ALTER TABLE ${quoted(Tables.tagVersions)} '
        'ALTER COLUMN project_id SET NOT NULL',
    // 6. The new keys.
    'ALTER TABLE ${quoted(Tables.tags)} '
        'DROP CONSTRAINT ${quoted('${Tables.tags}_pkey')}',
    'ALTER TABLE ${quoted(Tables.tags)} ADD PRIMARY KEY (tag_id, project_id)',
    'ALTER TABLE ${quoted(Tables.tagVersions)} '
        'DROP CONSTRAINT ${quoted('${Tables.tagVersions}_pkey')}',
    'ALTER TABLE ${quoted(Tables.tagVersions)} '
        'ADD PRIMARY KEY (tag_version_id, project_id)',
    // 7. The widened references go back on, and `Tags` and `Tag_Versions`
    //    join the project/sequence index every scoped table has.
    for (final fk in widened) alterAddForeignKey(fk),
    'CREATE INDEX ${quoted('idx_${Tables.tags}_project_seq'.toLowerCase())} '
        'ON ${quoted(Tables.tags)} (project_id, server_seq)',
    'CREATE INDEX '
        '${quoted('idx_${Tables.tagVersions}_project_seq'.toLowerCase())} '
        'ON ${quoted(Tables.tagVersions)} (project_id, server_seq)',
    'DROP INDEX ${quoted('idx_${Tables.tags}_seq'.toLowerCase())}',
    'DROP INDEX ${quoted('idx_${Tables.tagVersions}_seq'.toLowerCase())}',
  ];
}

/// Schema v15 (task 11.225): the app's counterpart re-points a "no signal"
/// entry's tag ids after schema v14's fork split a collar two projects held
/// (`lib/data/db/non_detection_relink_migration.dart`). **No statement here,
/// deliberately.**
///
/// `schemaV14Statements` above scopes every `Tags` row to "the one project
/// that holds it" and **refuses** a tag linked to two — the server never
/// forks a collar, so there is no forked tag id for a `Non_Detections` row
/// to dangle from. (This used to cite `TAG_COPY_ON_ADD_DESIGN.md` §3.4's
/// "there is no production data" as the reason; task 11.227 struck that
/// sentence — the beta server holds five collars — and the reason that
/// still holds is the refusal, not the absence of data.) This entry exists
/// only so [serverMigrations] stays defined through [latestSchemaVersion],
/// the way every other minor bump does.
List<String> schemaV15Statements() => [];

/// Schema v16 (task 11.240): the animal gets a row of its own.
///
/// Mirrors the app's `schemaV16Statements` in `lib/data/db/schema.dart`,
/// which carries the argument: a `Tags` row was already a deployment of one
/// transmitter on one animal, `Individuals` is the animal, `Tags.individual_id`
/// names it, and colour moves to the animal because it was always the
/// animal's. **Not additive, and this paragraph originally said it was.** A
/// new table and a nullable column are; *"one `NOT NULL` relaxed"* is not: a
/// v15 app handed a v16 tag row refuses it at its own `Tags.color_hex TEXT
/// NOT NULL`, the page rolls back, and its sync never advances again — while
/// both builds announce the same major. Measured by task 11.242
/// (`test/data/sync/v15_device_meets_v16_row_test.dart` in the app), which
/// moved [schemaMajorVersion] to **4** so the v15 build is refused instead,
/// and froze the wire's shape so the next relaxation fails a test
/// (`wire_shape_freeze.dart`). The parenthetical that stood here — *there are
/// no such builds in the field, and the app and server move together* — was
/// true and was the wrong kind of argument: the boundary exists so that
/// sentence never has to be.
///
/// **The backfill is deterministic on purpose, and identical to the app's.**
/// One individual per tag, `individual_id = tag_id`, `lineage_id = tag_id`,
/// wearing the tag's name and colour, tombstoned if the tag is. A device that
/// has already run its own v16 arrives at exactly these rows, so the two
/// sides converge without either re-sending anything — the same reason v14
/// set `lineage_id = tag_id` on both sides. **No name-matching**: two tags
/// called "Marie" become two individuals, and merging them is a person's act
/// (task 11.241).
///
/// **Backfilled rows get a `server_seq`**, reserved from `sync_seq_counter`
/// in one block the way `ServerSeq.reserve` does, because a row with none is
/// never delivered by pull — a device joining the project later would get
/// every tag and no animal. The `Tags` rows are updated in place *without* a
/// new `server_seq`, as v14 did: a device that has migrated already holds
/// the same values, and one that has not yet migrated will compute them.
///
/// The last statement returns the census, which `PostgresMigrations.run`
/// prints — a migration that creates a row per existing row and prints
/// nothing cannot be told from one that created none.
List<String> schemaV16Statements() {
  const table = Tables.individuals;
  const tags = Tables.tags;
  final tagCount = 'SELECT count(*) FROM ${quoted(tags)}';
  return [
    'CREATE TABLE ${quoted(table)} ('
        'individual_id TEXT NOT NULL, '
        'project_id TEXT NOT NULL, '
        'name TEXT NOT NULL, '
        'color_hex TEXT NOT NULL, '
        'status TEXT NOT NULL, '
        'species TEXT, '
        'sex TEXT, '
        'notes TEXT, '
        'lineage_id TEXT NOT NULL, '
        'copied_at TEXT, '
        'created_at TEXT NOT NULL, '
        'updated_at TEXT NOT NULL, '
        'deleted_at TEXT, '
        'revision BIGINT NOT NULL, '
        'last_modified_by TEXT, '
        'origin_device_id TEXT, '
        'server_seq BIGINT, '
        'received_at TIMESTAMPTZ NOT NULL DEFAULT now(), '
        'clock_skew_flag TEXT, '
        'PRIMARY KEY (individual_id, project_id))',
    'ALTER TABLE ${quoted(tags)} ADD COLUMN individual_id TEXT',
    'ALTER TABLE ${quoted(tags)} ALTER COLUMN color_hex DROP NOT NULL',
    // The backfill. One block of sequence values, sized to the tag count,
    // handed out in a stable order; the `UPDATE ... RETURNING` in the CTE
    // takes the counter's row lock for the rest of this transaction, which
    // is the commit-ordering guarantee `sync_seq_counter` exists for.
    'WITH block AS ('
        'UPDATE sync_seq_counter '
        'SET next_value = next_value + ($tagCount) '
        'WHERE only_row '
        'RETURNING next_value - ($tagCount) AS before) '
        'INSERT INTO ${quoted(table)} '
        '(individual_id, project_id, name, color_hex, status, species, sex, '
        'notes, lineage_id, copied_at, created_at, updated_at, deleted_at, '
        'revision, last_modified_by, origin_device_id, server_seq) '
        'SELECT t.tag_id, t.project_id, t.tag_name, t.color_hex, '
        "CASE t.status WHEN 'active' THEN 'alive' ELSE 'unknown' END, "
        'NULL, NULL, NULL, t.tag_id, NULL, t.created_at, t.updated_at, '
        't.deleted_at, 0, t.last_modified_by, t.origin_device_id, '
        'block.before + row_number() OVER (ORDER BY t.tag_id, t.project_id) '
        'FROM ${quoted(tags)} t, block',
    'UPDATE ${quoted(tags)} SET individual_id = tag_id, color_hex = NULL',
    alterAddForeignKey((
      table,
      const ['project_id'],
      Tables.projects,
      const ['project_id'],
    )),
    alterAddForeignKey((
      tags,
      const ['individual_id', 'project_id'],
      table,
      const ['individual_id', 'project_id'],
    )),
    'CREATE INDEX ${quoted('idx_${table}_project_seq'.toLowerCase())} '
        'ON ${quoted(table)} (project_id, server_seq)',
    'CREATE INDEX ${quoted('idx_${table}_skew'.toLowerCase())} '
        'ON ${quoted(table)} (clock_skew_flag) WHERE clock_skew_flag IS NOT NULL',
    'CREATE INDEX ${quoted('idx_tags_individual')} '
        'ON ${quoted(tags)} (individual_id)',
    // The census. Returned rather than logged from Dart, so it lands where
    // every other migration's findings land — `PostgresMigrations.run`
    // prefixes it with the version.
    "SELECT format('%s tag row(s) found; %s individual(s) created, one per "
        "tag, none merged by name; %s tag(s) now name their animal', "
        '($tagCount), (SELECT count(*) FROM ${quoted(table)}), '
        '(SELECT count(*) FROM ${quoted(tags)} t JOIN ${quoted(table)} i '
        'ON i.individual_id = t.individual_id '
        'AND i.project_id = t.project_id))',
  ];
}

/// Schema v18 (task 11.56): `Projects` gains `lineage_id` and `copied_at`,
/// the provenance pair `Tags` and `Individuals` already carry — which
/// projects are seasons of one study, and when the copy was made.
///
/// Mirrors the app's `schemaV18Statements` in `lib/data/db/schema.dart`. Both
/// columns are nullable because this is a minor: a v17 device sends neither,
/// and `NOT NULL` here would refuse its every `Projects` row. The backfill
/// writes each existing project's lineage as its own id — true, because
/// nobody copied it — and a null arriving later from an older peer reads as
/// the same thing on every device.
List<String> schemaV18Statements() => [
  'ALTER TABLE ${quoted(Tables.projects)} ADD COLUMN lineage_id TEXT',
  'ALTER TABLE ${quoted(Tables.projects)} ADD COLUMN copied_at TEXT',
  'UPDATE ${quoted(Tables.projects)} SET lineage_id = project_id '
      'WHERE lineage_id IS NULL',
];

/// Schema v19 (task 11.323, **major 6**): an estimate may have **no
/// ellipse**, and the three ellipse columns empty together say so.
///
/// Mirrors the app's `schemaV19Statements` in `lib/data/db/schema.dart`,
/// which has to rebuild the table because SQLite cannot drop `NOT NULL`;
/// Postgres can, in place. **There is nothing to rewrite here:** the app's
/// 0 × 0 rows are the ones this server always refused (an axis must be
/// greater than zero), so no such row was ever stored.
List<String> schemaV19Statements() => [
  for (final column in const [
    'semi_major_axis',
    'semi_minor_axis',
    'rotation_angle',
  ])
    'ALTER TABLE ${quoted(Tables.estimatedPositions)} '
        'ALTER COLUMN $column DROP NOT NULL',
];

/// Schema v20 (task 11.331): `Projects.time_zone` and `Deployments.time_zone`
/// — the field site's zone, and the zone each deployment row's days were
/// written in (IANA names).
///
/// Mirrors the app's `schemaV20Statements` in `lib/data/db/schema.dart`.
/// Nullable because this is a minor: a v19 device sends neither, and `NOT
/// NULL` would refuse its rows. **No backfill here**: which zone an existing
/// row was typed in is known, if at all, only on the phone that typed it,
/// whose own v20 step decides it. A row stored here with no zone is read the
/// way this server read every row before v20 — its ends as instants
/// (`DeploymentInterlock`'s `zonelessEndsAreInstants`).
List<String> schemaV20Statements() => [
  'ALTER TABLE ${quoted(Tables.projects)} ADD COLUMN time_zone TEXT',
  'ALTER TABLE ${quoted(Tables.deployments)} ADD COLUMN time_zone TEXT',
];

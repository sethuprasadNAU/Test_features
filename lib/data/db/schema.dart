/// Canonical SQLite DDL for the TriTrack schema (technical doc, "SQLite
/// Schema" + "Global Data Conventions").
///
/// Design notes baked in here:
/// - The six sync/merge columns are defined ONCE ([_syncColumns]) and
///   interpolated into every table, so the set can never drift between tables.
/// - The local/utc/offset timestamp triple is defined once ([_timeColumns],
///   parameterized by prefix) for the same reason.
/// - `last_modified_by` is intentionally NOT foreign-keyed (a merged row may
///   reference a user row that hasn't synced yet).
/// - Table creation order respects FK dependencies: a referenced table is
///   always created before the table that points at it.
/// - Indexes cover project_id / tag_id / timestamp on the high-volume tables
///   (Observations, Non_Detections, Estimated_Positions) as required, plus a
///   normalized-email index on Users for cross-device dedup and helpful
///   project/tag indexes on the remaining child tables.
library;

// `Tables` (the table name constants) now lives in `package:tritrack_sync` —
// the app and the future server must never disagree on a table's name. The
// `export` keeps every existing `import '.../db/schema.dart'` call site in
// this app working unchanged, since this file still needs `Tables` in scope
// for its own DDL below.
import 'package:tritrack_sync/tritrack_sync.dart';

export 'package:tritrack_sync/tritrack_sync.dart' show Tables;

/// The six global sync/merge columns present on every table.
const _syncColumns = '''
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  revision INTEGER NOT NULL DEFAULT 0,
  last_modified_by TEXT,
  origin_device_id TEXT''';

/// The local + UTC + offset timestamp triple for a recorded domain time.
///
/// [prefix] names the local/utc columns (e.g. `timestamp` → `timestamp_local`,
/// `timestamp_utc`). [offsetColumn] is passed explicitly because the spec does
/// not name it uniformly: the four domain-time tables use `timezone_offset`,
/// while Triangulation_Sessions uses `started_at_offset`.
String _timeColumns(String prefix, String offsetColumn) =>
    '''
  ${prefix}_local TEXT NOT NULL,
  ${prefix}_utc TEXT NOT NULL,
  $offsetColumn TEXT NOT NULL''';

const _createUsers =
    '''
CREATE TABLE ${Tables.users} (
  user_id TEXT PRIMARY KEY,
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  email TEXT NOT NULL,
$_syncColumns
)''';

const _createProjects =
    '''
CREATE TABLE ${Tables.projects} (
  project_id TEXT PRIMARY KEY,
  project_name TEXT NOT NULL,
  description TEXT,
  notes TEXT,
  owner_user_id TEXT NOT NULL REFERENCES ${Tables.users}(user_id),
  creation_date TEXT NOT NULL,
  bbox_min_lat REAL,
  bbox_min_lon REAL,
  bbox_max_lat REAL,
  bbox_max_lon REAL,
  datum TEXT NOT NULL DEFAULT 'WGS84',
$_syncColumns
)''';

const _createProjectMemberships =
    '''
CREATE TABLE ${Tables.projectMemberships} (
  membership_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  user_id TEXT NOT NULL REFERENCES ${Tables.users}(user_id),
  join_date TEXT NOT NULL,
  end_date TEXT,
  role TEXT NOT NULL,
$_syncColumns
)''';

const _createTags =
    '''
CREATE TABLE ${Tables.tags} (
  tag_id TEXT PRIMARY KEY,
  frequency_mhz REAL NOT NULL,
  pulse_rate REAL,
  pulse_pattern TEXT,
  tag_name TEXT NOT NULL,
  date_put_on TEXT NOT NULL,
  date_removed TEXT,
  status TEXT NOT NULL,
  capture_date TEXT,
  notes TEXT,
$_syncColumns
)''';

const _createProjectTags =
    '''
CREATE TABLE ${Tables.projectTags} (
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL REFERENCES ${Tables.tags}(tag_id),
  status TEXT NOT NULL,
$_syncColumns,
  PRIMARY KEY (project_id, tag_id)
)''';

String get _createTriangulationSessions =>
    '''
CREATE TABLE ${Tables.triangulationSessions} (
  session_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL REFERENCES ${Tables.tags}(tag_id),
  label TEXT,
${_timeColumns('started_at', 'started_at_offset')},
  notes TEXT,
$_syncColumns
)''';

String get _createObservations =>
    '''
CREATE TABLE ${Tables.observations} (
  observation_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  user_id TEXT NOT NULL REFERENCES ${Tables.users}(user_id),
  tag_id TEXT NOT NULL REFERENCES ${Tables.tags}(tag_id),
  session_id TEXT REFERENCES ${Tables.triangulationSessions}(session_id),
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  position_accuracy_m REAL,
  position_source TEXT NOT NULL,
  elevation REAL NOT NULL,
  altitude_agl REAL NOT NULL DEFAULT 0,
  observation_type TEXT NOT NULL,
  magnetic_bearing REAL,
  true_north_bearing REAL,
  bearing_uncertainty REAL,
  bearing_capture_method TEXT,
  bearing_method TEXT,
  magnetic_bearing_start REAL,
  magnetic_bearing_end REAL,
  true_north_bearing_start REAL,
  true_north_bearing_end REAL,
  magnetic_declination REAL,
  wmm_model_version TEXT,
  antenna_type TEXT,
  receiver_gain REAL,
  signal_type TEXT NOT NULL,
  signal_strength TEXT NOT NULL,
  bearing_quality TEXT,
  notes TEXT,
$_syncColumns
)''';

String get _createNonDetections =>
    '''
CREATE TABLE ${Tables.nonDetections} (
  non_detection_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  user_id TEXT NOT NULL REFERENCES ${Tables.users}(user_id),
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  position_accuracy_m REAL,
  position_source TEXT NOT NULL,
  elevation REAL NOT NULL,
  altitude_agl REAL NOT NULL DEFAULT 0,
  tag_ids_listened_for TEXT NOT NULL,
  notes TEXT,
$_syncColumns
)''';

/// `observation_ids_used` names the bearings an estimate was computed from —
/// unvalidated by design (see `unvalidatedIdListColumns`), and never
/// backfilled or rewritten once an estimate is saved.
///
/// **A season clone carries it across, deliberately** (`SeasonCloneDisposition
/// .lastKnownPerAnimal`, `season_clone.dart`): those bearings stay behind in
/// last season's project, so an id here can legitimately name a bearing this
/// project does not hold. That is the same kind of fact `lineage_id` is —
/// see §2.3 of the design and `TagColumnKind.provenance` — real and worth
/// keeping for a person reading two exported files or an analysis spanning
/// seasons, and inert for the app itself: nothing here decides access, and
/// the column is never cleared. What the *app* shows for an id that resolves
/// to nothing here is `EstimateBearingResolution`'s job
/// (`lib/core/utils/estimate_bearing_resolution.dart`, task 11.259), not
/// this column's.
String get _createEstimatedPositions =>
    '''
CREATE TABLE ${Tables.estimatedPositions} (
  position_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL REFERENCES ${Tables.tags}(tag_id),
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  semi_major_axis REAL NOT NULL,
  semi_minor_axis REAL NOT NULL,
  rotation_angle REAL NOT NULL,
  method TEXT NOT NULL,
  observation_ids_used TEXT NOT NULL,
  notes TEXT,
$_syncColumns
)''';

String get _createActualTagLocations =>
    '''
CREATE TABLE ${Tables.actualTagLocations} (
  location_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL REFERENCES ${Tables.tags}(tag_id),
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  uncertainty_radius REAL NOT NULL,
  notes TEXT,
$_syncColumns
)''';

const _createIndexes = [
  // Cross-device user dedup by normalized email.
  'CREATE INDEX idx_users_email ON ${Tables.users}(email)',
  // High-volume tables: project_id / tag_id / timestamp (required by spec).
  'CREATE INDEX idx_observations_project ON ${Tables.observations}(project_id)',
  'CREATE INDEX idx_observations_tag ON ${Tables.observations}(tag_id)',
  'CREATE INDEX idx_observations_ts ON ${Tables.observations}(timestamp_utc)',
  'CREATE INDEX idx_observations_session ON ${Tables.observations}(session_id)',
  'CREATE INDEX idx_nondetections_project ON ${Tables.nonDetections}(project_id)',
  'CREATE INDEX idx_nondetections_ts ON ${Tables.nonDetections}(timestamp_utc)',
  'CREATE INDEX idx_estpositions_project ON ${Tables.estimatedPositions}(project_id)',
  'CREATE INDEX idx_estpositions_tag ON ${Tables.estimatedPositions}(tag_id)',
  'CREATE INDEX idx_estpositions_ts ON ${Tables.estimatedPositions}(timestamp_utc)',
  // Remaining child tables: project/tag lookups.
  'CREATE INDEX idx_memberships_project ON ${Tables.projectMemberships}(project_id)',
  'CREATE INDEX idx_memberships_user ON ${Tables.projectMemberships}(user_id)',
  'CREATE INDEX idx_projecttags_tag ON ${Tables.projectTags}(tag_id)',
  'CREATE INDEX idx_sessions_project ON ${Tables.triangulationSessions}(project_id)',
  'CREATE INDEX idx_sessions_tag ON ${Tables.triangulationSessions}(tag_id)',
  'CREATE INDEX idx_actuallocations_project ON ${Tables.actualTagLocations}(project_id)',
  'CREATE INDEX idx_actuallocations_tag ON ${Tables.actualTagLocations}(tag_id)',
];

/// All statements to build schema v1, in execution order (tables first in
/// FK-safe order, then indexes).
List<String> schemaV1Statements() => [
  _createUsers,
  _createProjects,
  _createProjectMemberships,
  _createTags,
  _createProjectTags,
  _createTriangulationSessions,
  _createObservations,
  _createNonDetections,
  _createEstimatedPositions,
  _createActualTagLocations,
  ..._createIndexes,
];

/// Schema v2 (Phase 4): two Project Setup fields the spec named but the
/// original table didn't carry — `coordinate_format` (DD/DMS/UTM display
/// preference) and `triangulation_window_minutes` (the Position Estimation
/// temporal-spread warning threshold, default ~15-20min per the design doc).
/// Additive `ALTER TABLE`, per the "never edit a shipped migration" rule.
List<String> schemaV2Statements() => [
  "ALTER TABLE ${Tables.projects} ADD COLUMN coordinate_format TEXT NOT NULL DEFAULT 'dd'",
  'ALTER TABLE ${Tables.projects} ADD COLUMN triangulation_window_minutes INTEGER NOT NULL DEFAULT 15',
];

/// Schema v3: drop the `NOT NULL` on `Observations.tag_id` so a general
/// `note`-type observation can be recorded without tying it to a specific tag
/// (a geotagged/timed field note). SQLite can't relax a column constraint in
/// place, so this is the standard create-copy-drop-rename table rebuild — the
/// first non-additive migration. Safe because no other table has a foreign key
/// *into* Observations; its own FKs and every column/order are preserved, and
/// its four indexes (dropped with the old table) are recreated. `INSERT
/// … SELECT *` relies on the new table having identical columns in the same
/// order as the original.
List<String> schemaV3Statements() => [
  '''
CREATE TABLE ${Tables.observations}_new (
  observation_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  user_id TEXT NOT NULL REFERENCES ${Tables.users}(user_id),
  tag_id TEXT REFERENCES ${Tables.tags}(tag_id),
  session_id TEXT REFERENCES ${Tables.triangulationSessions}(session_id),
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  position_accuracy_m REAL,
  position_source TEXT NOT NULL,
  elevation REAL NOT NULL,
  altitude_agl REAL NOT NULL DEFAULT 0,
  observation_type TEXT NOT NULL,
  magnetic_bearing REAL,
  true_north_bearing REAL,
  bearing_uncertainty REAL,
  bearing_capture_method TEXT,
  bearing_method TEXT,
  magnetic_bearing_start REAL,
  magnetic_bearing_end REAL,
  true_north_bearing_start REAL,
  true_north_bearing_end REAL,
  magnetic_declination REAL,
  wmm_model_version TEXT,
  antenna_type TEXT,
  receiver_gain REAL,
  signal_type TEXT NOT NULL,
  signal_strength TEXT NOT NULL,
  bearing_quality TEXT,
  notes TEXT,
$_syncColumns
)''',
  'INSERT INTO ${Tables.observations}_new SELECT * FROM ${Tables.observations}',
  'DROP TABLE ${Tables.observations}',
  'ALTER TABLE ${Tables.observations}_new RENAME TO ${Tables.observations}',
  'CREATE INDEX idx_observations_project ON ${Tables.observations}(project_id)',
  'CREATE INDEX idx_observations_tag ON ${Tables.observations}(tag_id)',
  'CREATE INDEX idx_observations_ts ON ${Tables.observations}(timestamp_utc)',
  'CREATE INDEX idx_observations_session ON ${Tables.observations}(session_id)',
];

/// Schema v4 (Phase 4, "Tag Color Coding"): each tag gets a user-assignable
/// `color_hex`, auto-assigned round-robin from [TagColorPalette.colors] on
/// creation. Additive `ALTER TABLE`, but pre-existing rows all land on the
/// same `DEFAULT` value from the `ALTER TABLE` alone — the follow-up `UPDATE`
/// backfills them with distinct round-robin colors instead, keyed off
/// `rowid` order (a stand-in for creation order; there is no other stable
/// ordering column) via `COUNT(rowid <= self)` rather than a window function,
/// since older SQLite builds bundled on-device may predate `ROW_NUMBER()`.
List<String> schemaV4Statements() {
  final palette = TagColorPalette.colors;
  final whenClauses = [
    for (var i = 0; i < palette.length; i++) "WHEN $i THEN '${palette[i]}'",
  ].join('\n    ');
  return [
    "ALTER TABLE ${Tables.tags} ADD COLUMN color_hex TEXT NOT NULL DEFAULT '${palette.first}'",
    '''
UPDATE ${Tables.tags} SET color_hex = CASE ((
  SELECT COUNT(*) FROM ${Tables.tags} t2 WHERE t2.rowid <= ${Tables.tags}.rowid
) - 1) % ${palette.length}
    $whenClauses
  END
''',
  ];
}

const _createUserEmails =
    '''
CREATE TABLE ${Tables.userEmails} (
  user_email_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES ${Tables.users}(user_id),
  email TEXT NOT NULL,
  recorded_at TEXT NOT NULL,
$_syncColumns
)''';

/// Schema v5 (Phase 7, "Local User Identity"): a `User_Emails` table records
/// every address a user has ever used, so cross-device merge can dedupe two
/// devices' users even after one of them changes its email (the current
/// `Users.email` alone can't do this — see `ProjectMerger._buildUserRemap`'s
/// prior-email fallback). Brand-new table, so — unlike v2/v4's `ALTER
/// TABLE ... DEFAULT` — there is no existing-row backfill: an older backup's
/// row payload simply has no rows for this table (`SchemaMigrator` needs no
/// v5 step; `ProjectBackup.rowsFor` already defaults an absent table to
/// empty).
List<String> schemaV5Statements() => [
  _createUserEmails,
  'CREATE INDEX idx_user_emails_email ON ${Tables.userEmails}(email)',
  'CREATE INDEX idx_user_emails_user ON ${Tables.userEmails}(user_id)',
];

/// Schema v6 (task 10.35, **schema major 2**): primary keys on the six
/// project-scoped data tables become `(<id>, project_id)`.
///
/// Why this is worth a major bump — which `TriTrack_Technical_Context.md`'s
/// schema-evolution rules call a last resort — is argued in
/// `TriTrack_Security_Model.md` §4.13. In one line: a globally-unique row id
/// meant the server answered "does this id exist anywhere?" to anyone who
/// tried to create a row under it (D-1 arm (c)), *and* it permanently refused
/// Phase 6.3's shared observations, which by design keep the sender's
/// `observation_id` and by default land in a different project than they came
/// from.
///
/// **The id leads, the scope follows** — `(observation_id, project_id)`, not
/// the other way round. See the note on `syncTables` for why; briefly, the
/// leading key column is the one the index can be searched on alone, and
/// by-id lookup is the query this schema runs most.
///
/// **No data moves.** `project_id` is already a `NOT NULL` column on all six
/// tables, so every row's new key is derived entirely from what it already
/// holds. That is what makes `INSERT … SELECT *` sufficient here, and it is
/// also what lets `SchemaMigrator` carry a v1-major backup archive forward
/// rather than refusing it.
///
/// SQLite cannot alter a primary key in place, so this is v3's
/// create-copy-drop-rename rebuild applied six times. Two things differ from
/// v3, which rebuilt a table nothing referenced:
///
/// 1. **Order is parent-first.** `Observations.session_id` points at
///    `Triangulation_Sessions`, so that table is rebuilt (and renamed back
///    into place) before the table referencing it.
/// 2. **`Observations` gains a composite foreign key.** Once
///    `Triangulation_Sessions` is keyed `(session_id, project_id)`, a
///    single-column `REFERENCES … (session_id)` no longer names a unique key
///    and SQLite reports it as a foreign-key mismatch at the first write. The
///    FK becomes `(session_id, project_id) → (session_id, project_id)`.
///    `session_id` stays nullable, which is safe: SQLite's default MATCH
///    SIMPLE treats a composite FK with any NULL column as satisfied, so a
///    session-less observation is unconstrained exactly as before.
///
/// Foreign keys are enforced *off* while migrations run and back on
/// afterwards (see `AppDatabase._openOptions` and [runMigrations]), which is
/// SQLite's own prescribed procedure for a table rebuild — during step 1 above
/// the old `Observations` briefly references a table whose key shape has
/// already changed. `runMigrations` runs `PRAGMA foreign_key_check` before
/// handing the database back, so that window cannot close over a real
/// violation silently.
List<String> schemaV6Statements() => [
  // Parent-first: Triangulation_Sessions before Observations.
  ..._rekeyToProjectScope(
    Tables.projectMemberships,
    '''
  membership_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  user_id TEXT NOT NULL REFERENCES ${Tables.users}(user_id),
  join_date TEXT NOT NULL,
  end_date TEXT,
  role TEXT NOT NULL,
$_syncColumns,
  PRIMARY KEY (membership_id, project_id)''',
    const [
      'CREATE INDEX idx_memberships_project ON ${Tables.projectMemberships}(project_id)',
      'CREATE INDEX idx_memberships_user ON ${Tables.projectMemberships}(user_id)',
    ],
  ),
  ..._rekeyToProjectScope(
    Tables.triangulationSessions,
    '''
  session_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL REFERENCES ${Tables.tags}(tag_id),
  label TEXT,
${_timeColumns('started_at', 'started_at_offset')},
  notes TEXT,
$_syncColumns,
  PRIMARY KEY (session_id, project_id)''',
    const [
      'CREATE INDEX idx_sessions_project ON ${Tables.triangulationSessions}(project_id)',
      'CREATE INDEX idx_sessions_tag ON ${Tables.triangulationSessions}(tag_id)',
    ],
  ),
  ..._rekeyToProjectScope(
    Tables.observations,
    '''
  observation_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  user_id TEXT NOT NULL REFERENCES ${Tables.users}(user_id),
  tag_id TEXT REFERENCES ${Tables.tags}(tag_id),
  session_id TEXT,
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  position_accuracy_m REAL,
  position_source TEXT NOT NULL,
  elevation REAL NOT NULL,
  altitude_agl REAL NOT NULL DEFAULT 0,
  observation_type TEXT NOT NULL,
  magnetic_bearing REAL,
  true_north_bearing REAL,
  bearing_uncertainty REAL,
  bearing_capture_method TEXT,
  bearing_method TEXT,
  magnetic_bearing_start REAL,
  magnetic_bearing_end REAL,
  true_north_bearing_start REAL,
  true_north_bearing_end REAL,
  magnetic_declination REAL,
  wmm_model_version TEXT,
  antenna_type TEXT,
  receiver_gain REAL,
  signal_type TEXT NOT NULL,
  signal_strength TEXT NOT NULL,
  bearing_quality TEXT,
  notes TEXT,
$_syncColumns,
  PRIMARY KEY (observation_id, project_id),
  FOREIGN KEY (session_id, project_id)
    REFERENCES ${Tables.triangulationSessions}(session_id, project_id)''',
    const [
      'CREATE INDEX idx_observations_project ON ${Tables.observations}(project_id)',
      'CREATE INDEX idx_observations_tag ON ${Tables.observations}(tag_id)',
      'CREATE INDEX idx_observations_ts ON ${Tables.observations}(timestamp_utc)',
      'CREATE INDEX idx_observations_session ON ${Tables.observations}(session_id)',
    ],
  ),
  ..._rekeyToProjectScope(
    Tables.nonDetections,
    '''
  non_detection_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  user_id TEXT NOT NULL REFERENCES ${Tables.users}(user_id),
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  position_accuracy_m REAL,
  position_source TEXT NOT NULL,
  elevation REAL NOT NULL,
  altitude_agl REAL NOT NULL DEFAULT 0,
  tag_ids_listened_for TEXT NOT NULL,
  notes TEXT,
$_syncColumns,
  PRIMARY KEY (non_detection_id, project_id)''',
    const [
      'CREATE INDEX idx_nondetections_project ON ${Tables.nonDetections}(project_id)',
      'CREATE INDEX idx_nondetections_ts ON ${Tables.nonDetections}(timestamp_utc)',
    ],
  ),
  ..._rekeyToProjectScope(
    Tables.estimatedPositions,
    '''
  position_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL REFERENCES ${Tables.tags}(tag_id),
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  semi_major_axis REAL NOT NULL,
  semi_minor_axis REAL NOT NULL,
  rotation_angle REAL NOT NULL,
  method TEXT NOT NULL,
  observation_ids_used TEXT NOT NULL,
  notes TEXT,
$_syncColumns,
  PRIMARY KEY (position_id, project_id)''',
    const [
      'CREATE INDEX idx_estpositions_project ON ${Tables.estimatedPositions}(project_id)',
      'CREATE INDEX idx_estpositions_tag ON ${Tables.estimatedPositions}(tag_id)',
      'CREATE INDEX idx_estpositions_ts ON ${Tables.estimatedPositions}(timestamp_utc)',
    ],
  ),
  ..._rekeyToProjectScope(
    Tables.actualTagLocations,
    '''
  location_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL REFERENCES ${Tables.tags}(tag_id),
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  uncertainty_radius REAL NOT NULL,
  notes TEXT,
$_syncColumns,
  PRIMARY KEY (location_id, project_id)''',
    const [
      'CREATE INDEX idx_actuallocations_project ON ${Tables.actualTagLocations}(project_id)',
      'CREATE INDEX idx_actuallocations_tag ON ${Tables.actualTagLocations}(tag_id)',
    ],
  ),
];

/// One table's create-copy-drop-rename rebuild, for [schemaV6Statements].
///
/// [body] is the full column/constraint list of the rebuilt table; it must
/// declare the same columns in the same order as the table being replaced,
/// because the copy is `INSERT … SELECT *` (v3's constraint, unchanged).
/// [indexes] are the table's indexes, which `DROP TABLE` takes with it and
/// which must therefore be recreated verbatim.
List<String> _rekeyToProjectScope(
  String table,
  String body,
  List<String> indexes,
) => [
  'CREATE TABLE ${table}_new (\n$body\n)',
  'INSERT INTO ${table}_new SELECT * FROM $table',
  'DROP TABLE $table',
  'ALTER TABLE ${table}_new RENAME TO $table',
  ...indexes,
];

/// Schema v7 (task 11.7): `Observation_Exclusions` — the record that an
/// observation is out of position estimation, either because a better record
/// of the same event supersedes it or because an owner has judged it bad.
///
/// **Why a table and not two columns on `Observations`.** The observation is
/// never written by either action, which is the strongest available form of
/// 11.7's rule that neither may rewrite the original's `user_id`,
/// `last_modified_by`, or any measurement column. It is also the only shape
/// that *works*: `Observations` is author-only (Phase 8), sync authorizes
/// whole rows, and so an owner's mark stored on a colleague's observation
/// could never leave the device that made it. The full argument is on
/// `Tables.observationExclusions`.
///
/// **No foreign key into `Observations`, deliberately**, though `project_id`
/// keeps its ordinary one:
///
/// 1. `superseded_by_observation_id` may legitimately name a row that has not
///    arrived yet — Phase 6.3 replica import and the sync engine both deliver
///    rows in an order this table cannot constrain.
/// 2. Applying one to `observation_id` and not the other would be an
///    inconsistency with no principle behind it.
/// 3. `Observations` has never been referenced by another table, which is what
///    let schema v3 and v6 rebuild it with a plain create-copy-drop-rename.
///    Adding a reference would make every future rebuild of that table a
///    harder migration for no gain here.
///
/// A mark naming an observation this device does not hold simply matches
/// nothing — it is inert, not corrupt.
const _createObservationExclusions =
    '''
CREATE TABLE ${Tables.observationExclusions} (
  exclusion_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  observation_id TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES ${Tables.users}(user_id),
  kind TEXT NOT NULL,
  superseded_by_observation_id TEXT,
  reason TEXT,
$_syncColumns,
  PRIMARY KEY (exclusion_id, project_id)
)''';

List<String> schemaV7Statements() => [
  _createObservationExclusions,
  'CREATE INDEX idx_obs_exclusions_project '
      'ON ${Tables.observationExclusions}(project_id)',
  // The lookup the solver's input filter runs on every solve.
  'CREATE INDEX idx_obs_exclusions_observation '
      'ON ${Tables.observationExclusions}(observation_id)',
];

/// Schema v8 (task 11.10): a database constraint behind the one-open-
/// membership-per-project rule.
///
/// **The rule was code-only.** `ProjectMembershipRepository.findForUser` and
/// the server's `JoinService.approve` both read "is there already an open
/// row" and then write, and a read-then-write has a gap: two invitations for
/// the same person accepted at the same instant — two devices, or two
/// requests — can both pass the read before either writes. The check that
/// produces `RedemptionFailure.alreadyMember`, a message a person can read,
/// is kept; this index is the backstop for the race that check cannot close
/// on its own, matching Postgres's `schemaV8Statements` in
/// `server/lib/src/schema/postgres_schema.dart`, which the two must agree
/// with — either side can be the one accepting an invitation.
///
/// A **partial** unique index, not a plain one, because a person legitimately
/// holds several *closed* (ended or tombstoned) rows for the same project
/// over a rejoin history (task 11.2) — only one *open* row is the rule. Open
/// is `end_date IS NULL AND deleted_at IS NULL`, the same definition
/// [isOpenOwnerMembership] in `package:tritrack_sync` uses for the ownership
/// question (this index covers every role, not just `owner`).
List<String> schemaV8Statements() => [
  'CREATE UNIQUE INDEX idx_memberships_one_open '
      'ON ${Tables.projectMemberships}(project_id, user_id) '
      'WHERE end_date IS NULL AND deleted_at IS NULL',
];

/// Schema v9 (task 11.32): `Tag_Versions`, plus `Observations.tag_version_id`
/// pointing into it.
///
/// **What this is for, in one sentence.** A bearing recorded which tag it was
/// taken against and nothing more, so editing a tag's frequency or name
/// retroactively changed what every earlier bearing claimed to have been taken
/// against — and tags must be editable, because VHF transmitters drift and
/// names get corrected.
///
/// **Why a version table rather than columns on `Observations`.** The full
/// argument is on `Tables.tagVersions`; the short form is that "frequency,
/// pulse rate and name" is a hand-maintained list of the fields worth copying,
/// and this project had already found that exact drift four times in two weeks.
/// The version's column set is *derived* from `tagColumnKinds`, so declaring a
/// new tag column `measurementContext` is the whole of what it takes to make it
/// travel with every bearing.
///
/// **The DDL below is written out rather than generated from `tableSpecs`**,
/// for the reason [schemaV6Statements] and the server's `schemaV7Statements`
/// both give: a shipped migration must describe the change *as it was made*,
/// and a spec-derived one silently becomes a different migration the next time
/// the specs move — so a device that already ran v9 and a fresh install would
/// build different tables. What keeps the two honest instead is
/// `schema_matches_shared_spec_test.dart`, which compares the schema these
/// statements actually build against the derived spec: add a
/// `measurementContext` tag column without a v10 migration and that test is
/// red.
///
/// **Three deliberate absences.**
///
/// 1. **No foreign key from `Observations.tag_version_id`.** Same reasoning
///    `Observation_Exclusions` records for `superseded_by_observation_id`: sync
///    delivers rows in `server_seq` order across pages, so a bearing can
///    legitimately arrive before the version it names, and a pasted or imported
///    record may name a version this device will never hold. A dangling
///    reference here must be *inert*, not a refused row — an FK would turn one
///    unresolved bearing into a device that cannot sync at all. `Tag_Versions`
///    does keep its ordinary FK to `Tags`: a version cannot mean anything
///    without the tag it versions, and the two are delivered by the same
///    reachability.
/// 2. **No backfill.** Every row that predates this migration keeps
///    `tag_version_id` NULL, which reads as "not recorded" and never as
///    "whatever the tag says now". A bearing taken last season genuinely does
///    not know what the tag read at the time, and writing today's answer into
///    it is precisely the falsehood this task exists to remove.
/// 3. **No initial version row for existing tags.** Same reason. A version
///    invented now would be a claim about a past nobody observed, and the
///    bearings that would point at it are exactly the ones that must stay
///    honest about not knowing. The first version of an *existing* tag is
///    written the next time somebody edits it (see `TagVersionRepository`);
///    until then the tag has history the app declines to guess at.
const _createTagVersions =
    '''
CREATE TABLE ${Tables.tagVersions} (
  tag_version_id TEXT PRIMARY KEY,
  tag_id TEXT NOT NULL REFERENCES ${Tables.tags}(tag_id),
  effective_from TEXT NOT NULL,
  frequency_mhz REAL NOT NULL,
  pulse_rate REAL,
  pulse_pattern TEXT,
  tag_name TEXT NOT NULL,
$_syncColumns
)''';

List<String> schemaV9Statements() => [
  _createTagVersions,
  // The lookup every "what was this bearing recorded against?" read runs, and
  // the one `TagVersionRepository.currentFor` uses to find a tag's latest.
  'CREATE INDEX idx_tag_versions_tag ON ${Tables.tagVersions}(tag_id)',
  // Nullable and unindexed by design: it is read one row at a time, by id,
  // from a bearing already in hand.
  'ALTER TABLE ${Tables.observations} ADD COLUMN tag_version_id TEXT',
];

/// Schema v10 (task 11.33): what a ground-truth point records beyond a
/// position — **what was found**, and **what the tag read at the time**.
///
/// `Actual_Tag_Locations` has existed since v1 and nothing in the app has ever
/// written to it: the table, its sync rule, its repository and the map layer
/// that draws its points were all built, but no screen ever called the save.
/// Task 11.33 builds that screen, and these two columns are what it needs the
/// table to be able to say.
///
/// **`found_kind`** — one of `GroundTruthKind`'s three values. Only
/// `animal_and_collar` validates the triangulation of a live collared animal;
/// a `collar_only` point may be where the collar was shed days earlier, and
/// scoring an estimate against it would report the app as wrong when it was
/// right. Whatever later computes accuracy has to be able to tell them apart,
/// so the distinction is stored rather than inferred.
///
/// **`tag_version_id`** — the `Tag_Versions` row the tag read when the point
/// was taken, exactly as `Observations.tag_version_id` does for a bearing
/// (task 11.32). A truth point is the same kind of thing as a bearing: a field
/// record somebody took while standing in front of a collar. Without it, an
/// export of truth points made after a tag is renamed cannot be matched to the
/// animal it describes.
///
/// **No foreign key on `tag_version_id`, and no backfill of either column** —
/// both for the reasons `schemaV9Statements` sets out at length. Sync delivers
/// rows in `server_seq` order, so a point can legitimately arrive before the
/// version it names, and an unresolvable reference must be inert rather than a
/// refused row. A row written before this migration genuinely does not know
/// what was found or what the tag read, and writing today's answer into it
/// would be the exact falsehood 11.32 exists to remove. Both columns are
/// therefore nullable, and null reads as "not recorded".
///
/// **Two tables that name a tag and deliberately record no version — written
/// down here because an unexplained absence gets rediscovered as a gap by the
/// next sweep** (task 11.33's brief asks for exactly this):
///
/// 1. **`Estimated_Positions` — no.** An estimate is *derived* from the
///    bearings named in its own `observation_ids_used`, and each of those
///    bearings already records the version it was taken against. The
///    information is reachable without duplicating it, and a duplicate could
///    disagree with its own inputs.
/// 2. **`Triangulation_Sessions` — no.** A session is a grouping label for a
///    set of bearings, not a measurement of anything. It records no position,
///    no bearing and no signal, so there is no observation for a tag version
///    to give context to.
List<String> schemaV10Statements() => [
  'ALTER TABLE ${Tables.actualTagLocations} ADD COLUMN found_kind TEXT',
  'ALTER TABLE ${Tables.actualTagLocations} ADD COLUMN tag_version_id TEXT',
];

/// Schema v11 (task 11.93): **who found the truth point**, and **how its
/// position was got**.
///
/// ## `user_id` — who walked in and found it
///
/// Michael, 2026-08-31: *"the truth point should be recorded with the user
/// that logged it."* Until now the only person-shaped column on this table was
/// `last_modified_by`, which names whoever last **touched** the row — a
/// different fact, and one this project has repeatedly caught itself
/// presenting as the first. The consequences were already shipping: the Log's
/// observer filter hid every truth point, and the Team tab sorted them all
/// last under a blank.
///
/// **It records who found it. It is not a permission, and this migration must
/// not be read as one.** Any contributor on the project may still edit or
/// delete a truth point, exactly as task 11.92 shipped it —
/// `truthPointEditVerdict` is unchanged and
/// `truth_point_lifecycle_test.dart` asserts a non-author contributor can
/// still edit. Michael's reason is the case the feature exists for: **the
/// person who saw the pride and the person driving the truck may not be the
/// same person.**
///
/// ## `position_source` — a fix, a pin, or a fix somebody later nudged
///
/// `Observations` has recorded this since v1 and this table never did, so a
/// truth point could not say whether its coordinate was measured standing at
/// the collar or eyeballed across 200 m of savannah; the precision radius
/// carried that only by convention.
///
/// **Task 11.93 also made the position editable, which is what turned a
/// tolerable gap into a necessary column.** A point that began as a GPS fix
/// and was later moved by hand is a third thing, and nothing recorded it —
/// hence `PositionSource.gpsFixAdjusted`, and hence these two columns shipping
/// in one migration rather than two. Item 2 without item 3 would have shipped
/// a column whose meaning silently changed.
///
/// ## No backfill, on either column
///
/// The same rule [schemaV9Statements] and [schemaV10Statements] set out, and
/// here it is the whole point. An author backfilled from `last_modified_by`
/// would be a guess wearing a fact's clothing; a position source backfilled as
/// `gps_fix` would state a measurement nobody can vouch for. Both stay NULL
/// and read as **"not recorded"** on every screen — never as blank, which a
/// reader completes for themselves.
///
/// ## No foreign key on `user_id`, unlike `Observations.user_id`
///
/// Two reasons, and the first alone would settle it. **SQLite cannot add a
/// foreign key with `ALTER TABLE`** — it needs the whole-table rebuild schema
/// v6 did, on every device in the field, to buy a constraint. And the
/// constraint would be nearly redundant: the server's naming invariant already
/// refuses any `user_id` here but the caller's own
/// (`SyncTable.vouchesForAForeignNameIn`), and a caller has an authenticated
/// identity by definition. A dangling author would have to be a locally
/// corrupted row, which is not what a foreign key is defending against here.
List<String> schemaV11Statements() => [
  'ALTER TABLE ${Tables.actualTagLocations} ADD COLUMN user_id TEXT',
  'ALTER TABLE ${Tables.actualTagLocations} ADD COLUMN position_source TEXT',
];

/// Schema v12 (task 11.187): **a tag's pulse modes belong to the biologist who
/// entered the tag, not to the schema.**
///
/// Michael, 2026-09-07: *"There are always two pulse types currently (active
/// and mortality). The truth is that the person who enters the tag should be
/// able to set those, because some tags have only one mode and some have more
/// than one… The user should be able to toggle on/off up to three modes but not
/// fewer than 1."*
///
/// Three name/rate pairs on `Tags`, versioned like every other measurement
/// column, plus one slot number on `Observations`. `pulse_modes.dart` in
/// `package:tritrack_sync` carries the argument for that shape and for why slot
/// 1's rate stays in the column called `pulse_rate`.
///
/// ## What happens to a tag that already has a `pulse_rate`
///
/// **It keeps it, and it lands on mode 1.** No arithmetic runs on any stored
/// number — the unit was and remains beats per minute, so the seconds-per-pulse
/// toggle Michael asked for is a display preference and never a migration.
/// Mode 1 *is* `pulse_rate`, so a tag reading 52 bpm before this migration
/// reads "mode 1, 52 bpm" after it, byte-identically. It lands on mode 1 rather
/// than mode 2 because the build that wrote it offered one rate field and
/// defaulted every bearing to `regular_pulse`: the single stored number was the
/// rate of the mode the app called Regular, which is slot 1.
///
/// ## What the migration writes, and the one thing it refuses to write
///
/// **Names, yes.** Every existing tag and every existing `Tag_Versions` row
/// gets `pulse_mode_1_name = 'Normal'` and `pulse_mode_2_name = 'Mortality'`.
/// That is transcription, not invention: the build those rows were created
/// under offered exactly two modes to every collar, and Michael's answer of
/// 2026-09-07 says those records adopt the new default names ("the word
/// *Regular* leaves the app").
///
/// **A mortality rate, no.** `pulse_mode_2_rate_bpm` stays NULL on every
/// existing row. The old schema had one rate column and nowhere to record a
/// second, so any number written there would be a measurement nobody took —
/// the same rule `schemaV9Statements`, `schemaV10Statements` and
/// `schemaV11Statements` each state at length. Michael's 120 bpm is the default
/// a **newly created** tag gets, applied by the tag form, not by this
/// migration. An upgraded tag shows Mortality with a blank rate, which is
/// exactly what the device knows.
///
/// ## What a project synced from a server still on v11 does
///
/// **It arrives with modes and syncs normally.** v12 is purely additive on the
/// wire, so [schemaMajorVersion] stays at 2 and the two builds still speak: an
/// older peer preserves the five columns it does not recognise verbatim
/// (`UnknownColumnStore`) and hands them back untouched. Every new column is
/// nullable — including `pulse_mode_1_name`, deliberately — so a row pushed by
/// a v11 client, which cannot know these columns exist, is accepted rather than
/// refused by a NOT NULL it had no way to satisfy.
///
/// The cost is stated rather than hidden: a **tag created on a v11 client**
/// arrives here with no mode names at all. It reads as one mode called
/// "Normal" (`PulseModeSet.of` treats a null slot-1 name as the default and can
/// never return an empty list), and its Mortality mode is not there until
/// somebody adds it. A tag that already existed keeps both, because this
/// migration wrote them.
///
/// ## No backfill of `Observations.pulse_mode`, and none is needed
///
/// Every row written before v12 leaves it NULL and is read through
/// `signal_type` instead — `pulseModeSlotOf` maps `regular_pulse` to slot 1 and
/// `mortality_signal` to slot 2 **on read**, which is Michael's answer 3 with
/// no `UPDATE` behind it. Deriving it at read time rather than stamping a
/// number into several hundred thousand rows is the same choice schema v9 made
/// about `tag_version_id`, and it has the property that matters: nothing in the
/// database claims to know something it was never told.
///
/// ## Why `Tag_Versions` is rebuilt rather than altered
///
/// `Tables.tagVersions`' column list is **derived** from `Tags` through
/// `tagColumnKinds` — that derivation is the whole of task 11.32 and the reason
/// declaring a column `measurementContext` is all it takes to make it travel
/// with every bearing. The derived order puts the five new columns beside the
/// other measurement columns, *before* the sync columns; `ALTER TABLE ADD
/// COLUMN` can only append, which would put them after. Keeping the derivation
/// intact therefore means rebuilding the table, exactly as `schemaV3Statements`
/// and `schemaV6Statements` did.
///
/// The alternative was to split the derived list into "columns through v9" and
/// "columns added in v12" so the spec could describe the appended order — which
/// is a hand-maintained partition that grows a group every time somebody adds a
/// versioned column, i.e. the drift defect 11.32 exists to prevent, reinvented
/// inside the fix for it.
///
/// The rebuild is cheap and safe here: `Tag_Versions` is small, **no table has
/// a foreign key into it** (`Observations.tag_version_id` and
/// `Actual_Tag_Locations.tag_version_id` are deliberately unconstrained — see
/// `schemaV9Statements`), and its one outgoing key to `Tags` and its one index
/// are both recreated below. `_assertForeignKeysIntact` runs afterwards.
const _createTagVersionsV12 =
    '''
CREATE TABLE ${Tables.tagVersions}_new (
  tag_version_id TEXT PRIMARY KEY,
  tag_id TEXT NOT NULL REFERENCES ${Tables.tags}(tag_id),
  effective_from TEXT NOT NULL,
  frequency_mhz REAL NOT NULL,
  pulse_rate REAL,
  pulse_pattern TEXT,
  tag_name TEXT NOT NULL,
  pulse_mode_1_name TEXT,
  pulse_mode_2_name TEXT,
  pulse_mode_2_rate_bpm REAL,
  pulse_mode_3_name TEXT,
  pulse_mode_3_rate_bpm REAL,
$_syncColumns
)''';

List<String> schemaV12Statements() => [
  // `Tags` takes the five new columns by ALTER: the shared spec declares them
  // after `color_hex`, which is where appending puts them.
  'ALTER TABLE ${Tables.tags} ADD COLUMN pulse_mode_1_name TEXT',
  'ALTER TABLE ${Tables.tags} ADD COLUMN pulse_mode_2_name TEXT',
  'ALTER TABLE ${Tables.tags} ADD COLUMN pulse_mode_2_rate_bpm REAL',
  'ALTER TABLE ${Tables.tags} ADD COLUMN pulse_mode_3_name TEXT',
  'ALTER TABLE ${Tables.tags} ADD COLUMN pulse_mode_3_rate_bpm REAL',
  // The two modes every tag had under the old schema, written down. Not a
  // guess: it is what the build these rows were created under offered.
  "UPDATE ${Tables.tags} SET pulse_mode_1_name = 'Normal', "
      "pulse_mode_2_name = 'Mortality'",
  // `Tag_Versions` is rebuilt so the derived column order stays derivable —
  // see the note above. The column lists are written out on both sides of the
  // copy rather than using `SELECT *`, so a column that quietly moved would
  // fail loudly here instead of landing in the wrong slot.
  _createTagVersionsV12,
  'INSERT INTO ${Tables.tagVersions}_new ('
      'tag_version_id, tag_id, effective_from, frequency_mhz, pulse_rate, '
      'pulse_pattern, tag_name, pulse_mode_1_name, pulse_mode_2_name, '
      'created_at, updated_at, deleted_at, revision, last_modified_by, '
      'origin_device_id) '
      'SELECT tag_version_id, tag_id, effective_from, frequency_mhz, '
      "pulse_rate, pulse_pattern, tag_name, 'Normal', 'Mortality', "
      'created_at, updated_at, deleted_at, revision, last_modified_by, '
      'origin_device_id FROM ${Tables.tagVersions}',
  'DROP TABLE ${Tables.tagVersions}',
  'ALTER TABLE ${Tables.tagVersions}_new RENAME TO ${Tables.tagVersions}',
  // Dropped with the old table; recreated with the same name and shape
  // `schemaV9Statements` gave it.
  'CREATE INDEX idx_tag_versions_tag ON ${Tables.tagVersions}(tag_id)',
  // Which mode a bearing was heard on. Nullable, unindexed, never backfilled —
  // see the note above.
  'ALTER TABLE ${Tables.observations} ADD COLUMN pulse_mode INTEGER',
];

/// Schema v13 (task 11.193): **one bit saying the signal itself sounded
/// wrong.**
///
/// Michael, 2026-09-07: *"We should add a flag for all signal recordings — not
/// for a weak tag, but for one that seems to be malfunctioning, such as when
/// the inter-pulse duration is irregular."*
///
/// One nullable integer column on `Observations`, holding 0 or 1. The full
/// argument for the shape — why one bit rather than a scale, why it is not
/// `TagStatus.malfunction`, and why it withdraws nothing from analysis — is on
/// the column's own declaration in `table_columns.dart`, which is the file both
/// this schema and the server's are checked against.
///
/// ## What NULL means here, and why nothing backfills it
///
/// **NULL means nobody was asked.** Every row written before this migration has
/// it, and no `UPDATE` in this list turns any of them into a 0. A bearing taken
/// last season was recorded by somebody who was never shown the control, so the
/// database cannot know whether the pulses sounded even — and writing 0 would
/// say *"the person listened and it was fine"*, which is a claim nobody made.
/// That is the same rule `schemaV9Statements`, `schemaV11Statements` and
/// `schemaV12Statements` each state at length, and it matters more here than
/// for any of them: this flag's whole use is finding the collars that need
/// replacing, so a season of invented "sounded fine" rows is exactly the
/// falsehood that would hide one.
///
/// **0 is a real answer and the common one.** It means a signal was recorded,
/// the control was on the screen, and the person did not tick it. The three
/// record types with no signal in them — a note, a truth point, a no-signal
/// sweep — write NULL rather than 0, because the question has no meaning for a
/// record of not hearing anything.
///
/// ## A v12 peer
///
/// Additive and nullable, so [schemaMajorVersion] is unchanged and the two
/// builds still sync. A v12 client preserves the column verbatim without
/// understanding it (`UnknownColumnStore`) and hands it back; a row it pushes
/// carries no flag, which reads as "not recorded" — true of a build that could
/// not ask.
List<String> schemaV13Statements() => [
  'ALTER TABLE ${Tables.observations} ADD COLUMN signal_irregular INTEGER',
];

/// The device-local table name for the personal tag library — the lab's list
/// of transmitters, which **never crosses the wire** (task 11.219).
///
/// Deliberately not in `Tables`, which is the constant set the app and the
/// server share. This table has no server side, appears in no archive, and is
/// in neither `syncTables` nor `tableSpecs`; putting its name beside the
/// synced ones would invite somebody to add it to a list it must never
/// be on. Same reasoning as `UnknownColumnStore`'s holding table and
/// `SyncConflictStore`, which are client-only for the same reason and named
/// the same way.
const String kTagLibraryTable = 'Tag_Library';

/// Schema v14 (task 11.219, **schema major 3**): a tag belongs to one
/// project, and adding a tag to a project copies it.
///
/// The whole design is `CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md`; the argument
/// for spending a major bump is on `schemaMajorVersion`. What this file owns
/// is the SQLite half, and it is the largest rebuild since v6.
///
/// ## Why seven tables are rebuilt to add three columns
///
/// `Tags` becomes keyed `(tag_id, project_id)`. SQLite cannot alter a primary
/// key in place, so `Tags` itself is a create-copy-drop-rename — and the
/// moment its key is composite, **every single-column `REFERENCES
/// Tags(tag_id)` in the schema stops naming a unique key.** SQLite reports
/// that as a "foreign key mismatch" at the first write rather than tolerating
/// it, and `_assertForeignKeysIntact` catches it at the end of the migration.
/// So each of the five tables pointing at `Tags` is rebuilt too, its reference
/// widened to `(tag_id, project_id)` — the identical shape
/// `Observations.(session_id, project_id)` has carried since v6.
///
/// `Project_Tags` is the exception and its rebuild goes the other way: it
/// **loses** its foreign key into `Tags` rather than gaining a composite one.
/// The table is retained as the only durable record of what this migration
/// did (see [TagScopeMigration]), and a record of the past must not be able
/// to stop the app opening because the present schema moved underneath it.
/// Its reference to `Projects` is unchanged and kept.
///
/// ## What is not here
///
/// The census, the fork, and everything that decides *which* project a tag
/// belongs to are in [TagScopeMigration], because none of them is expressible
/// in DDL and all of them have to be printed. This library holds the
/// statements; that one holds the judgement.
const _createTagsV14 =
    '''
CREATE TABLE ${Tables.tags}_new (
  tag_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  frequency_mhz REAL NOT NULL,
  pulse_rate REAL,
  pulse_pattern TEXT,
  tag_name TEXT NOT NULL,
  date_put_on TEXT NOT NULL,
  date_removed TEXT,
  status TEXT NOT NULL,
  capture_date TEXT,
  notes TEXT,
$_syncColumns,
  color_hex TEXT NOT NULL DEFAULT '#E69F00',
  pulse_mode_1_name TEXT,
  pulse_mode_2_name TEXT,
  pulse_mode_2_rate_bpm REAL,
  pulse_mode_3_name TEXT,
  pulse_mode_3_rate_bpm REAL,
  lineage_id TEXT NOT NULL,
  copied_at TEXT,
  PRIMARY KEY (tag_id, project_id)
)''';

const _createTagVersionsV14 =
    '''
CREATE TABLE ${Tables.tagVersions}_new (
  tag_version_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL,
  effective_from TEXT NOT NULL,
  frequency_mhz REAL NOT NULL,
  pulse_rate REAL,
  pulse_pattern TEXT,
  tag_name TEXT NOT NULL,
  pulse_mode_1_name TEXT,
  pulse_mode_2_name TEXT,
  pulse_mode_2_rate_bpm REAL,
  pulse_mode_3_name TEXT,
  pulse_mode_3_rate_bpm REAL,
$_syncColumns,
  PRIMARY KEY (tag_version_id, project_id),
  FOREIGN KEY (tag_id, project_id)
    REFERENCES ${Tables.tags}(tag_id, project_id)
)''';

/// The personal tag library: every transmitter this device knows about, with
/// no project and no version history.
///
/// It is what a copy is made *from*, and the answer to "what is my lab's
/// transmitter list". It is device-local, so nothing here is authorization
/// state and no row of it is ever offered to a server or written to an
/// archive.
///
/// **`lineage_id` rather than a pointer at the copies** — see §2.3 of the
/// design and `TagColumnKind.provenance`. A library entry and every project
/// copy made from it share one lineage, which is what makes two projects'
/// tags recognisable as the same physical collar in an export without either
/// project's row ever naming anything outside itself.
///
/// **No `Tag_Versions` of its own, deliberately.** A version records what a
/// collar read when a bearing was taken against it, and nothing is ever
/// recorded against a library entry. The history lives beside the project
/// copy that has the bearings.
const _createTagLibraryV14 =
    '''
CREATE TABLE $kTagLibraryTable (
  tag_id TEXT PRIMARY KEY,
  lineage_id TEXT NOT NULL,
  frequency_mhz REAL NOT NULL,
  pulse_rate REAL,
  pulse_pattern TEXT,
  tag_name TEXT NOT NULL,
  date_put_on TEXT NOT NULL,
  date_removed TEXT,
  status TEXT NOT NULL,
  capture_date TEXT,
  notes TEXT,
$_syncColumns,
  color_hex TEXT NOT NULL DEFAULT '#E69F00',
  pulse_mode_1_name TEXT,
  pulse_mode_2_name TEXT,
  pulse_mode_2_rate_bpm REAL,
  pulse_mode_3_name TEXT,
  pulse_mode_3_rate_bpm REAL
)''';

/// `Project_Tags` rebuilt without its foreign key into `Tags` — see the note
/// on [schemaV14TableStatements]. Rows are preserved exactly; §3.5 of the
/// design forbids deleting them, because they are the audit trail of what the
/// fork did.
const _createProjectTagsV14 =
    '''
CREATE TABLE ${Tables.projectTags}_new (
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL,
  status TEXT NOT NULL,
$_syncColumns,
  PRIMARY KEY (project_id, tag_id)
)''';

String get _createTriangulationSessionsV14 =>
    '''
CREATE TABLE ${Tables.triangulationSessions}_new (
  session_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL,
  label TEXT,
${_timeColumns('started_at', 'started_at_offset')},
  notes TEXT,
$_syncColumns,
  PRIMARY KEY (session_id, project_id),
  FOREIGN KEY (tag_id, project_id)
    REFERENCES ${Tables.tags}(tag_id, project_id)
)''';

String get _createEstimatedPositionsV14 =>
    '''
CREATE TABLE ${Tables.estimatedPositions}_new (
  position_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL,
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  semi_major_axis REAL NOT NULL,
  semi_minor_axis REAL NOT NULL,
  rotation_angle REAL NOT NULL,
  method TEXT NOT NULL,
  observation_ids_used TEXT NOT NULL,
  notes TEXT,
$_syncColumns,
  PRIMARY KEY (position_id, project_id),
  FOREIGN KEY (tag_id, project_id)
    REFERENCES ${Tables.tags}(tag_id, project_id)
)''';

String get _createActualTagLocationsV14 =>
    '''
CREATE TABLE ${Tables.actualTagLocations}_new (
  location_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL,
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  uncertainty_radius REAL NOT NULL,
  notes TEXT,
$_syncColumns,
  found_kind TEXT,
  tag_version_id TEXT,
  -- No foreign key, exactly as `ALTER TABLE ADD COLUMN` left it in v11: a
  -- truth point may legitimately name a finder whose `Users` row has not
  -- arrived yet, and adding the constraint here would be a new refusal
  -- smuggled in under a rebuild that is supposed to change one reference.
  user_id TEXT,
  position_source TEXT,
  PRIMARY KEY (location_id, project_id),
  FOREIGN KEY (tag_id, project_id)
    REFERENCES ${Tables.tags}(tag_id, project_id)
)''';

String get _createObservationsV14 =>
    '''
CREATE TABLE ${Tables.observations}_new (
  observation_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  user_id TEXT NOT NULL REFERENCES ${Tables.users}(user_id),
  tag_id TEXT,
  session_id TEXT,
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  position_accuracy_m REAL,
  position_source TEXT NOT NULL,
  elevation REAL NOT NULL,
  altitude_agl REAL NOT NULL DEFAULT 0,
  observation_type TEXT NOT NULL,
  magnetic_bearing REAL,
  true_north_bearing REAL,
  bearing_uncertainty REAL,
  bearing_capture_method TEXT,
  bearing_method TEXT,
  magnetic_bearing_start REAL,
  magnetic_bearing_end REAL,
  true_north_bearing_start REAL,
  true_north_bearing_end REAL,
  magnetic_declination REAL,
  wmm_model_version TEXT,
  antenna_type TEXT,
  receiver_gain REAL,
  signal_type TEXT NOT NULL,
  signal_strength TEXT NOT NULL,
  bearing_quality TEXT,
  notes TEXT,
$_syncColumns,
  tag_version_id TEXT,
  pulse_mode INTEGER,
  signal_irregular INTEGER,
  PRIMARY KEY (observation_id, project_id),
  FOREIGN KEY (session_id, project_id)
    REFERENCES ${Tables.triangulationSessions}(session_id, project_id),
  FOREIGN KEY (tag_id, project_id)
    REFERENCES ${Tables.tags}(tag_id, project_id)
)''';

/// The column lists of the five tables rebuilt only to widen their reference
/// into `Tags`, written out on both sides of each copy rather than using
/// `SELECT *`.
///
/// Spelled out for the reason `schemaV12Statements` gives: a column that
/// quietly moved fails loudly here instead of landing in the wrong slot.
const _projectTagsColumnsV14 =
    'project_id, tag_id, status, created_at, updated_at, deleted_at, '
    'revision, last_modified_by, origin_device_id';
const _sessionsColumnsV14 =
    'session_id, project_id, tag_id, label, started_at_local, '
    'started_at_utc, started_at_offset, notes, created_at, updated_at, '
    'deleted_at, revision, last_modified_by, origin_device_id';
const _estimatedPositionsColumnsV14 =
    'position_id, project_id, tag_id, timestamp_local, timestamp_utc, '
    'timezone_offset, latitude, longitude, semi_major_axis, semi_minor_axis, '
    'rotation_angle, method, observation_ids_used, notes, created_at, '
    'updated_at, deleted_at, revision, last_modified_by, origin_device_id';
const _actualTagLocationsColumnsV14 =
    'location_id, project_id, tag_id, timestamp_local, timestamp_utc, '
    'timezone_offset, latitude, longitude, uncertainty_radius, notes, '
    'created_at, updated_at, deleted_at, revision, last_modified_by, '
    'origin_device_id, found_kind, tag_version_id, user_id, position_source';
const _observationsColumnsV14 =
    'observation_id, project_id, user_id, tag_id, session_id, '
    'timestamp_local, timestamp_utc, timezone_offset, latitude, longitude, '
    'position_accuracy_m, position_source, elevation, altitude_agl, '
    'observation_type, magnetic_bearing, true_north_bearing, '
    'bearing_uncertainty, bearing_capture_method, bearing_method, '
    'magnetic_bearing_start, magnetic_bearing_end, true_north_bearing_start, '
    'true_north_bearing_end, magnetic_declination, wmm_model_version, '
    'antenna_type, receiver_gain, signal_type, signal_strength, '
    'bearing_quality, notes, created_at, updated_at, deleted_at, revision, '
    'last_modified_by, origin_device_id, tag_version_id, pulse_mode, '
    'signal_irregular';

/// The `Tags` columns carried through the v14 rebuild unchanged — everything
/// the v13 table had. `project_id`, `lineage_id` and `copied_at` are supplied
/// by the copy rather than read from the old row, so they are not here.
const tagCarriedColumnsV14 =
    'tag_id, frequency_mhz, pulse_rate, pulse_pattern, tag_name, '
    'date_put_on, date_removed, status, capture_date, notes, created_at, '
    'updated_at, deleted_at, revision, last_modified_by, origin_device_id, '
    'color_hex, pulse_mode_1_name, pulse_mode_2_name, pulse_mode_2_rate_bpm, '
    'pulse_mode_3_name, pulse_mode_3_rate_bpm';

/// The `Tag_Versions` columns carried through unchanged; `project_id` is
/// supplied by the copy.
const _tagVersionCarriedColumnsV14 =
    'tag_version_id, tag_id, effective_from, frequency_mhz, pulse_rate, '
    'pulse_pattern, tag_name, pulse_mode_1_name, pulse_mode_2_name, '
    'pulse_mode_2_rate_bpm, pulse_mode_3_name, pulse_mode_3_rate_bpm, '
    'created_at, updated_at, deleted_at, revision, last_modified_by, '
    'origin_device_id';

/// The DDL and data movement of schema v14, in execution order.
///
/// **[TagScopeMigration] calls this; nothing else should.** It runs after the
/// census has been taken and `_tag_scope` — the temporary table naming which
/// project each surviving original `tag_id` belongs to — has been built, and
/// before the fork re-points a second project's rows at their own copy of a
/// shared tag. Every statement below reads that table rather than deciding
/// anything itself; for a tag two projects hold it names the project that
/// keeps the original id, so the rebuild lands the original row there and
/// the fork (`TagScopeMigration.fork`) does the rest afterwards.
///
/// Parent-first, exactly as v6 was: `Tags` is rebuilt before the five tables
/// that reference it, and `Triangulation_Sessions` before `Observations`,
/// which references both.
List<String> schemaV14TableStatements() => [
  // 1. The library, and every tag this device knows about copied into it —
  //    including the orphans, which is what makes the library complete on
  //    day one rather than empty. A tag's own id becomes its lineage: already
  //    unique, already unguessable, and true, because nobody copied it.
  _createTagLibraryV14,
  'INSERT INTO $kTagLibraryTable ($tagCarriedColumnsV14, lineage_id) '
      'SELECT $tagCarriedColumnsV14, tag_id FROM ${Tables.tags}',

  // 2. `Tags` itself. The join to `_tag_scope` is what drops an orphan: a tag
  //    no project's data names has no row there, so it survives only in the
  //    library. `copied_at` stays NULL — a tag that was always in one project
  //    was not copied, and stamping today's date on it would be a claim about
  //    a past nobody observed (v9's rule, and v11's, and v12's).
  _createTagsV14,
  'INSERT INTO ${Tables.tags}_new '
      '($tagCarriedColumnsV14, project_id, lineage_id, copied_at) '
      'SELECT ${_prefixed(tagCarriedColumnsV14, 't')}, s.project_id, '
      't.tag_id, NULL '
      'FROM ${Tables.tags} t JOIN _tag_scope s ON s.tag_id = t.tag_id',
  'DROP TABLE ${Tables.tags}',
  'ALTER TABLE ${Tables.tags}_new RENAME TO ${Tables.tags}',
  'CREATE INDEX idx_tags_project ON ${Tables.tags}(project_id)',

  // 3. `Tag_Versions` follows its tag into that tag's project. A version of a
  //    tag that became library-only is dropped with it: a version chain is
  //    the drift record of a collar somebody was recording against, and the
  //    library holds no bearings for it to be the history of. The count is
  //    printed by the census rather than left to be discovered.
  _createTagVersionsV14,
  'INSERT INTO ${Tables.tagVersions}_new '
      '($_tagVersionCarriedColumnsV14, project_id) '
      'SELECT ${_prefixed(_tagVersionCarriedColumnsV14, 'v')}, s.project_id '
      'FROM ${Tables.tagVersions} v JOIN _tag_scope s ON s.tag_id = v.tag_id',
  'DROP TABLE ${Tables.tagVersions}',
  'ALTER TABLE ${Tables.tagVersions}_new RENAME TO ${Tables.tagVersions}',
  'CREATE INDEX idx_tag_versions_tag ON ${Tables.tagVersions}(tag_id)',
  'CREATE INDEX idx_tag_versions_project '
      'ON ${Tables.tagVersions}(project_id)',

  // 4. `Project_Tags`, rows untouched, foreign key into `Tags` dropped.
  _createProjectTagsV14,
  'INSERT INTO ${Tables.projectTags}_new ($_projectTagsColumnsV14) '
      'SELECT $_projectTagsColumnsV14 FROM ${Tables.projectTags}',
  'DROP TABLE ${Tables.projectTags}',
  'ALTER TABLE ${Tables.projectTags}_new RENAME TO ${Tables.projectTags}',
  'CREATE INDEX idx_projecttags_tag ON ${Tables.projectTags}(tag_id)',

  // 5. The four tables whose `tag_id` becomes a same-project composite
  //    reference. Parent before child.
  _createTriangulationSessionsV14,
  'INSERT INTO ${Tables.triangulationSessions}_new ($_sessionsColumnsV14) '
      'SELECT $_sessionsColumnsV14 FROM ${Tables.triangulationSessions}',
  'DROP TABLE ${Tables.triangulationSessions}',
  'ALTER TABLE ${Tables.triangulationSessions}_new '
      'RENAME TO ${Tables.triangulationSessions}',
  'CREATE INDEX idx_sessions_project ON ${Tables.triangulationSessions}(project_id)',
  'CREATE INDEX idx_sessions_tag ON ${Tables.triangulationSessions}(tag_id)',

  _createObservationsV14,
  'INSERT INTO ${Tables.observations}_new ($_observationsColumnsV14) '
      'SELECT $_observationsColumnsV14 FROM ${Tables.observations}',
  'DROP TABLE ${Tables.observations}',
  'ALTER TABLE ${Tables.observations}_new RENAME TO ${Tables.observations}',
  'CREATE INDEX idx_observations_project ON ${Tables.observations}(project_id)',
  'CREATE INDEX idx_observations_tag ON ${Tables.observations}(tag_id)',
  'CREATE INDEX idx_observations_ts ON ${Tables.observations}(timestamp_utc)',
  'CREATE INDEX idx_observations_session ON ${Tables.observations}(session_id)',

  _createEstimatedPositionsV14,
  'INSERT INTO ${Tables.estimatedPositions}_new '
      '($_estimatedPositionsColumnsV14) '
      'SELECT $_estimatedPositionsColumnsV14 FROM ${Tables.estimatedPositions}',
  'DROP TABLE ${Tables.estimatedPositions}',
  'ALTER TABLE ${Tables.estimatedPositions}_new '
      'RENAME TO ${Tables.estimatedPositions}',
  'CREATE INDEX idx_estpositions_project ON ${Tables.estimatedPositions}(project_id)',
  'CREATE INDEX idx_estpositions_tag ON ${Tables.estimatedPositions}(tag_id)',
  'CREATE INDEX idx_estpositions_ts ON ${Tables.estimatedPositions}(timestamp_utc)',

  _createActualTagLocationsV14,
  'INSERT INTO ${Tables.actualTagLocations}_new '
      '($_actualTagLocationsColumnsV14) '
      'SELECT $_actualTagLocationsColumnsV14 FROM ${Tables.actualTagLocations}',
  'DROP TABLE ${Tables.actualTagLocations}',
  'ALTER TABLE ${Tables.actualTagLocations}_new '
      'RENAME TO ${Tables.actualTagLocations}',
  'CREATE INDEX idx_actuallocations_project ON ${Tables.actualTagLocations}(project_id)',
  'CREATE INDEX idx_actuallocations_tag ON ${Tables.actualTagLocations}(tag_id)',
];

/// `a, b` → `x.a, x.b`. Used only by the two copies above that read their
/// source through a join and so need every column qualified.
String _prefixed(String columns, String alias) =>
    columns.split(', ').map((c) => '$alias.$c').join(', ');

/// Schema v16 (task 11.240): the animal gets a row of its own.
///
/// A `Tags` row was already a *deployment* — one transmitter on one animal
/// between `date_put_on` and `date_removed` — and its `tag_name` was doing
/// the animal's job. `Individuals` is the animal; `Tags.individual_id` names
/// it; colour moves to the animal because it was always the animal's (Marie
/// is one colour across both her collars). Shaped on `Tags` because the
/// reasoning is identical: project-scoped, keyed `(individual_id,
/// project_id)`, with a sealed `lineage_id` that says two seasons' rows are
/// one bird to an export and to nothing live.
///
/// **What this migration does, and the one thing it refuses to do.** One
/// individual per existing tag, carrying that tag's name and colour, keyed
/// by that tag's own id. It **never** merges two tags into one individual
/// because their names match: two collars labelled "Marie" may be one bird,
/// a reused name, or a colliding typo, and deciding which is the app
/// fabricating a scientific claim nobody made. Merging is a person's act
/// (task 11.241).
///
/// **Why `individual_id = tag_id`, on every side of the wire.** The server's
/// v16 migration and an archive's v16 step do the same backfill. If each
/// side minted a random id, two devices migrating the same project would
/// create two individuals for every collar and the server would keep both.
/// Deriving the id from the tag's makes the three backfills agree without
/// talking — the same move as v14's `lineage_id = tag_id`. It is an artefact
/// of this backfill only; an individual created afterwards gets a fresh id.
///
/// **Why `Tags` is rebuilt rather than `ALTER TABLE ... ADD COLUMN`.** The
/// new column's foreign key is composite — `(individual_id, project_id)`
/// into `Individuals`, the same shape every reference into `Tags` has had
/// since v14 — and SQLite cannot add a table constraint to an existing
/// table. The rebuild also makes `color_hex` nullable, which `ALTER` cannot
/// do either. Same create-copy-drop-rename as v14, with foreign keys off
/// and `_assertForeignKeysIntact` afterwards; no other table changes shape.
const _createIndividuals =
    '''
CREATE TABLE ${Tables.individuals} (
  individual_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  name TEXT NOT NULL,
  color_hex TEXT NOT NULL,
  status TEXT NOT NULL,
  species TEXT,
  sex TEXT,
  notes TEXT,
  lineage_id TEXT NOT NULL,
  copied_at TEXT,
$_syncColumns,
  PRIMARY KEY (individual_id, project_id)
)''';

/// `Tags` at v16: `color_hex` nullable (retired — see
/// `TagColumnKind.retired`), `individual_id` appended, and a composite
/// reference into `Individuals`.
const _createTagsV16 =
    '''
CREATE TABLE ${Tables.tags}_new (
  tag_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  frequency_mhz REAL NOT NULL,
  pulse_rate REAL,
  pulse_pattern TEXT,
  tag_name TEXT NOT NULL,
  date_put_on TEXT NOT NULL,
  date_removed TEXT,
  status TEXT NOT NULL,
  capture_date TEXT,
  notes TEXT,
$_syncColumns,
  color_hex TEXT,
  pulse_mode_1_name TEXT,
  pulse_mode_2_name TEXT,
  pulse_mode_2_rate_bpm REAL,
  pulse_mode_3_name TEXT,
  pulse_mode_3_rate_bpm REAL,
  lineage_id TEXT NOT NULL,
  copied_at TEXT,
  individual_id TEXT,
  PRIMARY KEY (tag_id, project_id),
  FOREIGN KEY (individual_id, project_id)
    REFERENCES ${Tables.individuals}(individual_id, project_id)
)''';

/// The `Tags` columns carried through the v16 rebuild unchanged — every v15
/// column except `color_hex`, which is nulled by the copy after the backfill
/// has read it, and `individual_id`, which the copy supplies.
const tagCarriedColumnsV16 =
    'tag_id, project_id, frequency_mhz, pulse_rate, pulse_pattern, tag_name, '
    'date_put_on, date_removed, status, capture_date, notes, created_at, '
    'updated_at, deleted_at, revision, last_modified_by, origin_device_id, '
    'pulse_mode_1_name, pulse_mode_2_name, pulse_mode_2_rate_bpm, '
    'pulse_mode_3_name, pulse_mode_3_rate_bpm, lineage_id, copied_at';

/// The DDL and data movement of schema v16, in execution order.
///
/// `IndividualBackfillMigration.apply` runs this and prints the census;
/// nothing else should call it.
///
/// The backfill's `status` is the one judgement here, and it is a default,
/// not a claim about identity: a collar that is `active` is on an animal
/// presumed alive — the assumption every screen already made by showing the
/// tag — and every other collar state (recovered, lost, malfunctioning)
/// says nothing about the bird, so the animal reads `unknown` until a
/// person says otherwise. Tombstoned tags get tombstoned individuals, so a
/// removed collar's animal does not appear from nowhere.
List<String> schemaV16Statements() => [
  // 1. The animals: one per tag, keyed by the tag's id, wearing the tag's
  //    name and colour. Its lineage is its own id — nothing was copied.
  _createIndividuals,
  'INSERT INTO ${Tables.individuals} '
      '(individual_id, project_id, name, color_hex, status, species, sex, '
      'notes, lineage_id, copied_at, created_at, updated_at, deleted_at, '
      'revision, last_modified_by, origin_device_id) '
      'SELECT tag_id, project_id, tag_name, color_hex, '
      "CASE status WHEN 'active' THEN 'alive' ELSE 'unknown' END, "
      'NULL, NULL, NULL, tag_id, NULL, created_at, updated_at, deleted_at, '
      '0, last_modified_by, origin_device_id '
      'FROM ${Tables.tags}',
  'CREATE INDEX idx_individuals_project ON ${Tables.individuals}(project_id)',

  // 2. `Tags` rebuilt: colour nulled, the animal named.
  _createTagsV16,
  'INSERT INTO ${Tables.tags}_new ($tagCarriedColumnsV16, color_hex, '
      'individual_id) '
      'SELECT $tagCarriedColumnsV16, NULL, tag_id FROM ${Tables.tags}',
  'DROP TABLE ${Tables.tags}',
  'ALTER TABLE ${Tables.tags}_new RENAME TO ${Tables.tags}',
  'CREATE INDEX idx_tags_project ON ${Tables.tags}(project_id)',
  'CREATE INDEX idx_tags_individual ON ${Tables.tags}(individual_id)',
];

/// Schema v17 (task 11.243, **schema major 5**): a tag is equipment, the link
/// is a dated row, **and the collar data is deleted on purpose.**
///
/// `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` is the decision;
/// `Tables.deployments` carries the model. What this file owns is the SQLite
/// half, and the thing to understand before reading it is that **this
/// migration destroys data and that is its job** (§9).
///
/// ## Why there is no data-preserving path
///
/// Michael decided on 2026-09-14 that he will wipe: every device and the beta
/// server hold development data only. So the tag-and-observation tables are
/// emptied and `Tags` is rebuilt at its new shape, rather than a migration
/// being written to carry five test rows across. **A migration that preserves
/// nothing is machinery serving nothing** — and this project has built
/// elaborate paths for a handful of rows before (v14's fork, v15's relink),
/// each of which then had to be kept correct forever.
///
/// The spurious animals task 11.240's backfill created — one per collar,
/// wearing the collar's name — go the same way, rather than being cleaned up
/// by a screen nobody would ever need again.
///
/// ## What survives, which is the half a person cares about
///
/// **`Users`, `User_Emails`, `Projects` and `Project_Memberships` are
/// untouched.** Signing in, the project, and who is on the team all survive;
/// what has to be re-entered is the collars and the animals. `Project_Tags`
/// also survives, unemptied: it is the only durable record of what the v14
/// fork did (design §3.5) and it has had no foreign key into `Tags` since
/// v14, so nothing dangles.
///
/// ## Why every tag-bearing table is emptied and not just `Tags`
///
/// Not a decision about how much to delete — an arithmetic one. Every one of
/// them carries a `REFERENCES Tags(tag_id, project_id)`, so a row surviving a
/// wiped `Tags` is a dangling reference, and `_assertForeignKeysIntact` fails
/// the migration on exactly that. A bearing whose collar no longer exists is
/// also not a record of anything.
///
/// `Observations` **keeps its shape** — this migration does not touch a
/// column of it. Design §7: a bearing names a tag version and nothing else,
/// and there is no `individual_id` on it, ever.
const _createDeployments =
    '''
CREATE TABLE ${Tables.deployments} (
  deployment_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL,
  individual_id TEXT NOT NULL,
  attached_date TEXT,
  removed_date TEXT,
  notes TEXT,
$_syncColumns,
  PRIMARY KEY (deployment_id, project_id),
  FOREIGN KEY (tag_id, project_id)
    REFERENCES ${Tables.tags}(tag_id, project_id),
  FOREIGN KEY (individual_id, project_id)
    REFERENCES ${Tables.individuals}(individual_id, project_id)
)''';

/// `Tags` at v17: the four deployment columns gone, and with them the
/// composite reference into `Individuals` that v16 added.
///
/// Rebuilt rather than `ALTER TABLE ... DROP COLUMN` because the table
/// constraint has to go too, and SQLite cannot drop one. The rebuild is
/// create-drop-rename with **no copy**, which is what makes it a wipe rather
/// than a migration.
///
/// **`tag_name` keeps its name here on purpose (task 11.245).** It is the
/// tag's own identifier, not an animal's — renaming the column would be wire
/// churn with no behavioural gain, so every screen reads *"Tag ID"* off a
/// column still called `tag_name`. See `Tag.tagName`'s doc comment for the
/// same note, closer to where the app reads it.
const _createTagsV17 =
    '''
CREATE TABLE ${Tables.tags}_new (
  tag_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  frequency_mhz REAL NOT NULL,
  pulse_rate REAL,
  pulse_pattern TEXT,
  tag_name TEXT NOT NULL,
  status TEXT NOT NULL,
  notes TEXT,
$_syncColumns,
  color_hex TEXT,
  pulse_mode_1_name TEXT,
  pulse_mode_2_name TEXT,
  pulse_mode_2_rate_bpm REAL,
  pulse_mode_3_name TEXT,
  pulse_mode_3_rate_bpm REAL,
  lineage_id TEXT NOT NULL,
  copied_at TEXT,
  PRIMARY KEY (tag_id, project_id)
)''';

/// The device's personal tag library at v17, rebuilt for the same reason and
/// emptied with everything else.
///
/// **It is not on the wire and it is wiped anyway**, which is a judgement the
/// design does not make and this file should say out loud. The library is the
/// person's equipment inventory, so §3's *"a tag is equipment"* applies to it
/// exactly; keeping its rows while every project's collars go would leave a
/// library full of transmitters no project holds, and the form that edits
/// both would still have to ask for a `date_put_on` that only one of them
/// has. Michael is re-entering his collars once either way.
const _createTagLibraryV17 =
    '''
CREATE TABLE ${kTagLibraryTable}_new (
  tag_id TEXT PRIMARY KEY,
  lineage_id TEXT NOT NULL,
  frequency_mhz REAL NOT NULL,
  pulse_rate REAL,
  pulse_pattern TEXT,
  tag_name TEXT NOT NULL,
  status TEXT NOT NULL,
  notes TEXT,
$_syncColumns,
  color_hex TEXT,
  pulse_mode_1_name TEXT,
  pulse_mode_2_name TEXT,
  pulse_mode_2_rate_bpm REAL,
  pulse_mode_3_name TEXT,
  pulse_mode_3_rate_bpm REAL
)''';

/// The tables schema v17 empties, **child before parent**, so that every
/// `DELETE` runs while its own foreign keys still resolve.
///
/// `Tags`, `Tag_Library` and `Individuals` are absent because they are
/// dropped outright rather than emptied — see [schemaV17Statements].
const deploymentWipeTables = [
  Tables.observationExclusions,
  Tables.observations,
  Tables.triangulationSessions,
  Tables.nonDetections,
  Tables.estimatedPositions,
  Tables.actualTagLocations,
  Tables.tagVersions,
];

/// The DDL and deletions of schema v17, in execution order.
///
/// `DeploymentWipeMigration.apply` runs this and prints the census; nothing
/// else should call it. **A migration that deletes a row per existing row and
/// prints nothing cannot be told from one that deleted none**, which is this
/// project's founding defect met in the worst possible place — so the count
/// is taken first and the numbers are the finding.
List<String> schemaV17Statements() => [
  // 1. Everything that names a tag, child first.
  for (final table in deploymentWipeTables) 'DELETE FROM $table',

  // 2. `Tags` and the library, rebuilt empty at the new shape. No copy: the
  //    absence of an `INSERT ... SELECT` here is the whole of "there is no
  //    data-preserving path".
  _createTagsV17,
  'DROP TABLE ${Tables.tags}',
  'ALTER TABLE ${Tables.tags}_new RENAME TO ${Tables.tags}',
  'CREATE INDEX idx_tags_project ON ${Tables.tags}(project_id)',

  _createTagLibraryV17,
  'DROP TABLE $kTagLibraryTable',
  'ALTER TABLE ${kTagLibraryTable}_new RENAME TO $kTagLibraryTable',

  // 3. The animals. Emptied rather than dropped — the table's shape is
  //    unchanged (design §5 adds nothing to it; `unknown` was already an
  //    `IndividualStatus` value when 11.240 built it) — and emptied because
  //    what it holds today is one fabricated animal per collar, named after
  //    the collar, created by 11.240's backfill.
  'DELETE FROM ${Tables.individuals}',

  // 4. The dated link, created last: its foreign keys name the two tables
  //    above and SQLite resolves them at write time, not at create time, but
  //    the order is the one the merger and the publisher use.
  _createDeployments,
  'CREATE INDEX idx_deployments_project ON ${Tables.deployments}(project_id)',
  'CREATE INDEX idx_deployments_tag ON ${Tables.deployments}(tag_id)',
  'CREATE INDEX idx_deployments_individual '
      'ON ${Tables.deployments}(individual_id)',
];

/// Schema v18 (task 11.56): a project remembers which study it is a season
/// of.
///
/// Two nullable columns on `Projects`, with the meaning the pair has on
/// `Tags` (v14) and `Individuals` (v16): `lineage_id` is shared by every copy
/// of a project — Ponui 2025 and the Ponui 2026 started from it — and
/// `copied_at` is when the copy was made. Read by nothing live; sealed by
/// `provenanceColumns`.
///
/// **A minor, not a major, and that decides the shape.** Both columns are
/// nullable so a v17 device's `Projects` row — which carries neither — is
/// still a row the server accepts; `wire_shape_freeze.dart` refuses a `NOT
/// NULL` addition for exactly that reason. The `UPDATE` writes every existing
/// project's lineage as its own id, which is what v14 did for tags and is
/// true for the same reason: nobody copied it. A v17 peer that later
/// overwrites the row with a null lineage costs nothing, because every reader
/// treats null as the project's own id (`Project.effectiveLineageId`).
List<String> schemaV18Statements() => [
  'ALTER TABLE ${Tables.projects} ADD COLUMN lineage_id TEXT',
  'ALTER TABLE ${Tables.projects} ADD COLUMN copied_at TEXT',
  'UPDATE ${Tables.projects} SET lineage_id = project_id '
      'WHERE lineage_id IS NULL',
];

/// Schema v19 (task 11.323, **major 6**): an estimate may have **no ellipse**.
///
/// `semi_major_axis`, `semi_minor_axis` and `rotation_angle` lose `NOT NULL`,
/// and the three empty together mean *no ellipse* — the honest record of a
/// two-bearing estimate, whose bearings cross exactly and leave no scatter to
/// measure. Until now the app wrote 0 × 0 m there: a perfectly precise
/// position, which the sync rules refused (an axis must be greater than
/// zero), so the estimate stayed on the phone.
///
/// **SQLite cannot drop `NOT NULL` in place**, so the table is rebuilt —
/// v14's shape exactly, keys and composite reference included, with the three
/// columns nullable. Every row is copied; **a row with an axis that is not
/// greater than zero has all three emptied**, because that is the only thing
/// such a row can have meant (the 0 × 0 written for a missing ellipse) and the
/// sync rules refuse it as it stands. Its sync metadata is left alone: the
/// server refused it, so there is no copy elsewhere to reconcile with. A row
/// already held as refused stays held until *Try again*.
List<String> schemaV19Statements() => [
  _createEstimatedPositionsV19,
  'INSERT INTO ${Tables.estimatedPositions}_new '
      '($_estimatedPositionsColumnsV14) '
      'SELECT ${_estimatedPositionsColumnsV14.replaceAll(
        'semi_major_axis, semi_minor_axis, rotation_angle',
        '$_ellipsePresent THEN semi_major_axis END, '
            '$_ellipsePresent THEN semi_minor_axis END, '
            '$_ellipsePresent THEN rotation_angle END',
      )} '
      'FROM ${Tables.estimatedPositions}',
  'DROP TABLE ${Tables.estimatedPositions}',
  'ALTER TABLE ${Tables.estimatedPositions}_new '
      'RENAME TO ${Tables.estimatedPositions}',
  'CREATE INDEX idx_estpositions_project ON ${Tables.estimatedPositions}(project_id)',
  'CREATE INDEX idx_estpositions_tag ON ${Tables.estimatedPositions}(tag_id)',
  'CREATE INDEX idx_estpositions_ts ON ${Tables.estimatedPositions}(timestamp_utc)',
];

/// The ellipse is kept only when both axes are measurements.
const _ellipsePresent =
    'CASE WHEN semi_major_axis > 0 AND semi_minor_axis > 0';

String get _createEstimatedPositionsV19 =>
    '''
CREATE TABLE ${Tables.estimatedPositions}_new (
  position_id TEXT NOT NULL,
  project_id TEXT NOT NULL REFERENCES ${Tables.projects}(project_id),
  tag_id TEXT NOT NULL,
${_timeColumns('timestamp', 'timezone_offset')},
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  semi_major_axis REAL,
  semi_minor_axis REAL,
  rotation_angle REAL,
  method TEXT NOT NULL,
  observation_ids_used TEXT NOT NULL,
  notes TEXT,
$_syncColumns,
  PRIMARY KEY (position_id, project_id),
  FOREIGN KEY (tag_id, project_id)
    REFERENCES ${Tables.tags}(tag_id, project_id)
)''';

/// Schema v20 (task 11.331): the field site's time zone.
///
/// `Projects.time_zone` is the project's zone (an IANA name); each
/// `Deployments.time_zone` is the zone that row's days were written in. Both
/// nullable because this is a minor: a v19 device sends neither, and `NOT
/// NULL` would refuse its rows. The statements only add the columns; which
/// zone each existing row gets is decided in Dart, because it needs the
/// bundled boundaries and the phone's clock — see
/// `ProjectTimeZoneMigration`.
List<String> schemaV20Statements() => [
  'ALTER TABLE ${Tables.projects} ADD COLUMN time_zone TEXT',
  'ALTER TABLE ${Tables.deployments} ADD COLUMN time_zone TEXT',
];

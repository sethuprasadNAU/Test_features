import 'db_codec.dart';
import 'schema_constants.dart';
import 'sync_tables.dart';

/// Thrown when a backup archive is corrupt, truncated, not a TriTrack backup,
/// or otherwise unreadable. The importer catches this to warn the user WITHOUT
/// touching the existing project (the technical doc's "handle corrupt/partial
/// zips without wiping the existing project").
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;
  @override
  String toString() => 'BackupFormatException: $message';
}

/// Thrown when a backup's schema **major** is newer than this app understands.
///
/// A newer *minor* is not too new (task 10.18): its extra columns are held
/// verbatim by `UnknownColumnStore` and handed back untouched, which is what
/// made relaxing this safe. A newer major carries changes preservation cannot
/// absorb, so it is still refused rather than partially read.
class SchemaTooNewException implements Exception {
  const SchemaTooNewException({
    required this.backupVersion,
    required this.appVersion,
  });
  final int backupVersion;
  final int appVersion;
  @override
  String toString() =>
      'SchemaTooNewException: backup schema v$backupVersion is newer than this '
      'app supports (v$appVersion). Update the app to import it.';
}

/// Identifies the archive as a TriTrack project backup and pins the *envelope*
/// format (the manifest/data.json layout), independent of the SQLite
/// `schema_version` it carries.
///
/// Not renamed alongside the Dart package rename: this value is persisted
/// into every backup manifest and compared against on import, so changing
/// it would make every existing backup file unreadable.
const String kBackupFormatId = 'tri_track_project_backup';
const int kBackupFormatVersion = 1;

/// Archive entry names inside the `.zip`.
const String kManifestEntry = 'manifest.json';
const String kDataEntry = 'data.json';

/// The metadata header stored as `manifest.json` in the archive. Read first on
/// import so version/identity can be validated before the (larger) row payload
/// is trusted.
class BackupManifest {
  const BackupManifest({
    required this.formatId,
    required this.formatVersion,
    required this.schemaVersion,
    required this.createdAtUtc,
    required this.projectId,
    required this.projectName,
    required this.rowCounts,
    this.schemaMajor = schemaMajorVersion,
  });

  final String formatId;
  final int formatVersion;

  /// The SQLite `PRAGMA user_version` the row payload was written at — the
  /// minor half. Drives forward-migration on restore; a value *above* this
  /// build's is fine, since the columns it doesn't know are preserved.
  final int schemaVersion;

  /// The schema major the payload was written at — the compatibility boundary
  /// (task 10.18). Defaults rather than being required so a manifest written
  /// before this field existed still parses as the only major there has been.
  final int schemaMajor;
  final DateTime createdAtUtc;
  final String projectId;
  final String projectName;

  /// Row count per table (includes tombstoned rows). Diagnostic + used to
  /// cross-check the decoded payload isn't truncated.
  final Map<String, int> rowCounts;

  int get totalRows => rowCounts.values.fold(0, (a, b) => a + b);

  Map<String, Object?> toJson() => {
    'format_id': formatId,
    'format_version': formatVersion,
    'schema_version': schemaVersion,
    'schema_major': schemaMajor,
    'created_at': DbCodec.encodeUtc(createdAtUtc),
    'project_id': projectId,
    'project_name': projectName,
    'row_counts': rowCounts,
  };

  /// Parses and validates a manifest map. Throws [BackupFormatException] if any
  /// required field is missing or the format id/version is not recognized.
  factory BackupManifest.fromJson(Map<String, Object?> json) {
    final formatId = json['format_id'];
    if (formatId != kBackupFormatId) {
      throw BackupFormatException(
        'Not a TriTrack backup (format id: ${formatId ?? 'missing'}).',
      );
    }
    final formatVersion = _requireInt(json, 'format_version');
    if (formatVersion > kBackupFormatVersion) {
      throw BackupFormatException(
        'Backup envelope format v$formatVersion is newer than this app '
        'supports (v$kBackupFormatVersion).',
      );
    }
    final rawCounts = json['row_counts'];
    final rowCounts = <String, int>{};
    if (rawCounts is Map) {
      rawCounts.forEach((k, v) {
        if (v is int && k is String) rowCounts[k] = v;
      });
    }
    // Task 10.67: `json['schema_major'] is int ? ...! as int : schemaMajorVersion`
    // silently treated a PRESENT-but-wrong-typed major (e.g. a string) the
    // same as an ABSENT one — defaulting it to this build's own major rather
    // than refusing it, which is the exact "coerce bad input into the
    // permitted value" shape task 10.64 flagged: a manifest that lies about
    // its major would be taken at face value instead of rejected. Absent
    // (pre-10.18 manifest) still defaults, by design (see the field's own
    // doc comment); present-and-wrong is now a refusal like every other
    // field here.
    final rawSchemaMajor = json['schema_major'];
    if (rawSchemaMajor != null && rawSchemaMajor is! int) {
      throw BackupFormatException(
        'Backup manifest "schema_major" is not an integer.',
      );
    }
    return BackupManifest(
      formatId: _requireString(json, 'format_id'),
      formatVersion: formatVersion,
      schemaVersion: _requireInt(json, 'schema_version'),
      schemaMajor: rawSchemaMajor as int? ?? schemaMajorVersion,
      createdAtUtc: _decodeManifestUtc(json, 'created_at'),
      projectId: _requireString(json, 'project_id'),
      projectName: _requireString(json, 'project_name'),
      rowCounts: rowCounts,
    );
  }

  static Object _requireField(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) {
      throw BackupFormatException('Backup manifest is missing "$key".');
    }
    return value;
  }

  static int _requireInt(Map<String, Object?> json, String key) {
    final value = _requireField(json, key);
    if (value is! int) {
      throw BackupFormatException('Backup manifest "$key" is not an integer.');
    }
    return value;
  }

  /// Task 10.67: was `json[key]! as String` — a present-but-wrong-typed
  /// value (e.g. `"project_id": 123`) threw an uncaught `TypeError` instead
  /// of the [BackupFormatException] this factory's own doc comment promises
  /// every caller.
  static String _requireString(Map<String, Object?> json, String key) {
    final value = _requireField(json, key);
    if (value is! String) {
      throw BackupFormatException('Backup manifest "$key" is not a string.');
    }
    return value;
  }

  /// [DbCodec.decodeUtc] throws [DbCodecFormatException] on a wrong-typed or
  /// unparseable value — a different type than every other check in this
  /// factory, which would let it slip past a caller that only catches
  /// [BackupFormatException] exactly as promised. Re-thrown as that type here
  /// rather than widening the type callers have to catch.
  static DateTime _decodeManifestUtc(Map<String, Object?> json, String key) {
    try {
      return DbCodec.decodeUtc(_requireField(json, key));
    } on DbCodecFormatException catch (e) {
      throw BackupFormatException('Backup manifest "$key": ${e.message}');
    }
  }
}

/// A whole project's data in memory: the [manifest] plus every table's rows as
/// raw column-maps (the same maps a model's `toColumns()` produces / `fromRow`
/// consumes). This is the unit the archive encodes and the merger consumes.
class ProjectBackup {
  const ProjectBackup({required this.manifest, required this.tables});

  final BackupManifest manifest;

  /// table name -> list of column-map rows (tombstoned rows included).
  final Map<String, List<Map<String, Object?>>> tables;

  List<Map<String, Object?>> rowsFor(String table) => tables[table] ?? const [];

  /// The single project row this backup is built around, or null if absent
  /// (a malformed backup). Convenience for callers that need the project name
  /// / owner before merging.
  Map<String, Object?>? get projectRow {
    final rows = tables[Tables.projects];
    if (rows == null) return null;
    for (final row in rows) {
      if (row['project_id'] == manifest.projectId) return row;
    }
    return rows.isEmpty ? null : rows.first;
  }
}

/// Builds the row-count map for a manifest from a collected table set.
Map<String, int> rowCountsOf(Map<String, List<Map<String, Object?>>> tables) {
  return {
    for (final t in syncTables)
      if ((tables[t.name] ?? const []).isNotEmpty)
        t.name: tables[t.name]!.length,
  };
}

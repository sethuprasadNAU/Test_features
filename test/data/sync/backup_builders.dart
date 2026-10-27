import 'package:tritrack_sync/tritrack_sync.dart';

/// Wraps a table→rows map into a [ProjectBackup] with a well-formed manifest,
/// so merge/migrate tests can hand-craft payloads without going through the
/// archive codec.
ProjectBackup makeBackup(
  Map<String, List<Map<String, Object?>>> tables, {
  int schemaVersion = 2,
  int schemaMajor = schemaMajorVersion,
  String projectId = 'project-1',
  String projectName = 'Mesa Coyotes',
}) {
  return ProjectBackup(
    manifest: BackupManifest(
      formatId: kBackupFormatId,
      formatVersion: kBackupFormatVersion,
      schemaVersion: schemaVersion,
      schemaMajor: schemaMajor,
      createdAtUtc: DateTime.utc(2026, 7, 17, 12),
      projectId: projectId,
      projectName: projectName,
      rowCounts: rowCountsOf(tables),
    ),
    tables: tables,
  );
}

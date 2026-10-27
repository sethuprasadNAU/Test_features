import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

void main() {
  group('BackupManifest', () {
    test('toJson/fromJson round-trips', () {
      final manifest = BackupManifest(
        formatId: kBackupFormatId,
        formatVersion: kBackupFormatVersion,
        schemaVersion: latestSchemaVersion,
        createdAtUtc: DateTime.utc(2026, 7, 16, 18, 30),
        projectId: 'proj-1',
        projectName: 'Test Project',
        rowCounts: {Tables.observations: 3},
      );
      final decoded = BackupManifest.fromJson(manifest.toJson());
      expect(decoded.formatId, manifest.formatId);
      expect(decoded.schemaVersion, manifest.schemaVersion);
      expect(decoded.createdAtUtc, manifest.createdAtUtc);
      expect(decoded.projectId, manifest.projectId);
      expect(decoded.rowCounts, manifest.rowCounts);
      expect(decoded.totalRows, 3);
    });

    test('rejects a manifest with the wrong format id', () {
      expect(
        () => BackupManifest.fromJson({
          'format_id': 'not-a-tritrack-backup',
          'format_version': 1,
          'schema_version': 1,
          'created_at': '2026-07-16T18:30:00.000Z',
          'project_id': 'proj-1',
          'project_name': 'p',
        }),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('rejects a manifest from a newer envelope format', () {
      expect(
        () => BackupManifest.fromJson({
          'format_id': kBackupFormatId,
          'format_version': kBackupFormatVersion + 1,
          'schema_version': 1,
          'created_at': '2026-07-16T18:30:00.000Z',
          'project_id': 'proj-1',
          'project_name': 'p',
        }),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('rejects a manifest missing a required field', () {
      expect(
        () => BackupManifest.fromJson({
          'format_id': kBackupFormatId,
          'format_version': kBackupFormatVersion,
          'schema_version': 1,
        }),
        throwsA(isA<BackupFormatException>()),
      );
    });

    // Task 10.67: `project_id`/`project_name` used a naked `json[key]! as
    // String`, so a wrong-typed value threw an uncaught TypeError instead of
    // the BackupFormatException this factory's doc comment promises callers.
    test('rejects a manifest with a wrong-typed project_id', () {
      expect(
        () => BackupManifest.fromJson({
          'format_id': kBackupFormatId,
          'format_version': kBackupFormatVersion,
          'schema_version': 1,
          'created_at': '2026-07-16T18:30:00.000Z',
          'project_id': 12345,
          'project_name': 'p',
        }),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('rejects a manifest with a wrong-typed project_name', () {
      expect(
        () => BackupManifest.fromJson({
          'format_id': kBackupFormatId,
          'format_version': kBackupFormatVersion,
          'schema_version': 1,
          'created_at': '2026-07-16T18:30:00.000Z',
          'project_id': 'proj-1',
          'project_name': false,
        }),
        throwsA(isA<BackupFormatException>()),
      );
    });

    // Task 10.67: `created_at` reached `DbCodec.decodeUtc`'s naked
    // `value! as String` cast; a wrong-typed value threw a raw TypeError
    // rather than the promised BackupFormatException.
    test('rejects a manifest with a wrong-typed created_at', () {
      expect(
        () => BackupManifest.fromJson({
          'format_id': kBackupFormatId,
          'format_version': kBackupFormatVersion,
          'schema_version': 1,
          'created_at': 1721150200000,
          'project_id': 'proj-1',
          'project_name': 'p',
        }),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('rejects a manifest with an unparseable created_at', () {
      expect(
        () => BackupManifest.fromJson({
          'format_id': kBackupFormatId,
          'format_version': kBackupFormatVersion,
          'schema_version': 1,
          'created_at': 'not-a-timestamp',
          'project_id': 'proj-1',
          'project_name': 'p',
        }),
        throwsA(isA<BackupFormatException>()),
      );
    });

    // Task 10.67: a present-but-wrong-typed `schema_major` used to be
    // silently treated the same as an ABSENT one — defaulting to this
    // build's own major (`schemaMajorVersion`) rather than being refused.
    // That is the "coerce bad input into the permitted value" shape task
    // 10.64 flagged elsewhere: a manifest that lies about its major should
    // not be taken at face value.
    test('rejects a manifest with a wrong-typed schema_major', () {
      expect(
        () => BackupManifest.fromJson({
          'format_id': kBackupFormatId,
          'format_version': kBackupFormatVersion,
          'schema_version': 1,
          'schema_major': 'not-an-int',
          'created_at': '2026-07-16T18:30:00.000Z',
          'project_id': 'proj-1',
          'project_name': 'p',
        }),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('an absent schema_major still defaults, for pre-10.18 manifests', () {
      final decoded = BackupManifest.fromJson({
        'format_id': kBackupFormatId,
        'format_version': kBackupFormatVersion,
        'schema_version': 1,
        'created_at': '2026-07-16T18:30:00.000Z',
        'project_id': 'proj-1',
        'project_name': 'p',
      });
      expect(decoded.schemaMajor, schemaMajorVersion);
    });
  });

  group('SchemaTooNewException', () {
    test('carries both versions in its message', () {
      const e = SchemaTooNewException(backupVersion: 9, appVersion: 5);
      expect(e.toString(), contains('v9'));
      expect(e.toString(), contains('v5'));
    });
  });

  group('ProjectBackup', () {
    test('rowsFor defaults an absent table to empty', () {
      final backup = ProjectBackup(
        manifest: BackupManifest(
          formatId: kBackupFormatId,
          formatVersion: kBackupFormatVersion,
          schemaVersion: 1,
          createdAtUtc: DateTime.utc(2026, 7, 16),
          projectId: 'proj-1',
          projectName: 'p',
          rowCounts: const {},
        ),
        tables: const {},
      );
      expect(backup.rowsFor(Tables.observations), isEmpty);
    });
  });

  group('rowCountsOf', () {
    test('omits empty tables and counts the rest', () {
      final counts = rowCountsOf({
        Tables.observations: [
          {'observation_id': '1'},
          {'observation_id': '2'},
        ],
        Tables.tags: [],
      });
      expect(counts, {Tables.observations: 2});
    });
  });
}

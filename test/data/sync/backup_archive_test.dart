import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/backup_archive.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';
import 'backup_builders.dart';

void main() {
  group('BackupArchive round-trip', () {
    test('encode then decode preserves manifest and every row value', () {
      final tables = {
        Tables.users: [sampleUser().toColumns()],
        Tables.projects: [sampleProject().toColumns()],
        Tables.tags: [sampleTag().toColumns()],
        // NonDetection carries a JSON-list column and null optionals.
        Tables.nonDetections: [sampleNonDetection().toColumns()],
      };
      final backup = makeBackup(tables);

      final bytes = BackupArchive.encode(backup);
      final decoded = BackupArchive.decode(bytes);

      expect(decoded.manifest.formatId, kBackupFormatId);
      expect(decoded.manifest.projectId, 'project-1');
      expect(decoded.manifest.schemaVersion, 2);
      expect(decoded.manifest.rowCounts[Tables.users], 1);

      // Deep value equality on the round-tripped rows.
      expect(decoded.rowsFor(Tables.projects).single,
          equals(sampleProject().toColumns()));
      final nd = decoded.rowsFor(Tables.nonDetections).single;
      expect(nd['tag_ids_listened_for'], '["tag-1","tag-2"]');
      expect(nd['notes'], 'quiet');
      // A null optional survives as null (NonDetection has none null here, so
      // check the observation path too).
    });

    test('null optional columns survive the round-trip', () {
      final backup = makeBackup({
        Tables.observations: [sampleMinimalObservation().toColumns()],
      });
      final decoded = BackupArchive.decode(BackupArchive.encode(backup));
      final obs = decoded.rowsFor(Tables.observations).single;
      expect(obs.containsKey('magnetic_bearing'), isTrue);
      expect(obs['magnetic_bearing'], isNull);
      expect(obs['notes'], isNull);
    });

    test('produces a compact archive (well under the WhatsApp-transfer budget)',
        () {
      final tables = {
        Tables.observations: [
          for (var i = 0; i < 200; i++)
            sampleObservation(id: 'obs-$i').toColumns(),
        ],
      };
      final bytes = BackupArchive.encode(makeBackup(tables));
      // 200 fully-populated observations should compress to well below the
      // doc's ~250KB single-project envelope.
      expect(bytes.length, lessThan(250 * 1024));
    });
  });

  group('BackupArchive.decode rejects bad input without touching a database', () {
    test('random bytes are not a readable zip', () {
      final garbage = Uint8List.fromList(List.filled(64, 7));
      expect(() => BackupArchive.decode(garbage),
          throwsA(isA<BackupFormatException>()));
    });

    test('zip missing manifest.json throws', () {
      final archive = Archive()
        ..add(ArchiveFile.string(kDataEntry, '{}'));
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      expect(() => BackupArchive.decode(bytes),
          throwsA(isA<BackupFormatException>()));
    });

    test('zip missing data.json throws', () {
      final manifest = makeBackup({}).manifest.toJson();
      final archive = Archive()
        ..add(ArchiveFile.string(kManifestEntry, jsonEncode(manifest)));
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      expect(() => BackupArchive.decode(bytes),
          throwsA(isA<BackupFormatException>()));
    });

    test('wrong format id is rejected', () {
      final archive = Archive()
        ..add(ArchiveFile.string(
            kManifestEntry, jsonEncode({'format_id': 'something_else'})))
        ..add(ArchiveFile.string(kDataEntry, '{}'));
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      expect(() => BackupArchive.decode(bytes),
          throwsA(isA<BackupFormatException>()));
    });

    test('a newer envelope format_version is rejected', () {
      final manifest = makeBackup({}).manifest.toJson()
        ..['format_version'] = kBackupFormatVersion + 1;
      final archive = Archive()
        ..add(ArchiveFile.string(kManifestEntry, jsonEncode(manifest)))
        ..add(ArchiveFile.string(kDataEntry, '{}'));
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      expect(() => BackupArchive.decode(bytes),
          throwsA(isA<BackupFormatException>()));
    });

    test('malformed data.json JSON throws', () {
      final manifest = makeBackup({}).manifest.toJson();
      final archive = Archive()
        ..add(ArchiveFile.string(kManifestEntry, jsonEncode(manifest)))
        ..add(ArchiveFile.string(kDataEntry, 'not json{'));
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      expect(() => BackupArchive.decode(bytes),
          throwsA(isA<BackupFormatException>()));
    });

    test('unknown tables in data.json are ignored, not fatal', () {
      final manifest = makeBackup({}).manifest.toJson();
      final data = {
        'Some_Future_Table': [
          {'x': 1}
        ],
        Tables.users: [sampleUser().toColumns()],
      };
      final archive = Archive()
        ..add(ArchiveFile.string(kManifestEntry, jsonEncode(manifest)))
        ..add(ArchiveFile.string(kDataEntry, jsonEncode(data)));
      final bytes = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      final decoded = BackupArchive.decode(bytes);
      expect(decoded.tables.containsKey('Some_Future_Table'), isFalse);
      expect(decoded.rowsFor(Tables.users), hasLength(1));
    });
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:tritrack_sync/tritrack_sync.dart';

/// (De)serializes a [ProjectBackup] to/from a `.zip` archive — the shareable
/// artifact (technical doc: "~100–250KB, suitable for WhatsApp transfer").
///
/// Layout inside the zip:
/// - `manifest.json` — the [BackupManifest] (format/schema version, project id,
///   row counts). Read and validated first on import, before the payload.
/// - `data.json` — `{ "<table>": [ {column: value}, ... ] }`, one entry per
///   table with rows (tombstoned rows included so merge is lossless).
///
/// The column-map values are already JSON-native (String/num/null and JSON
/// text for list columns), so no custom (de)serialization is needed. [decode]
/// is defensive: any malformed/truncated/foreign archive throws
/// [BackupFormatException] *before* any database is touched, so a bad file can
/// never wipe the existing project.
abstract final class BackupArchive {
  /// Serializes [backup] to zip bytes. `manifest.json` is stored uncompressed
  /// (it's tiny and read first); `data.json` is deflated.
  static Uint8List encode(ProjectBackup backup) {
    final archive = Archive();

    final manifestJson = const JsonEncoder.withIndent('  ')
        .convert(backup.manifest.toJson());
    archive.add(ArchiveFile.string(kManifestEntry, manifestJson));

    // Only emit tables that actually have rows, in FK-safe order for
    // human-readability of the payload.
    //
    // **The `withheld` check is here as well as in `ProjectExporter`, and the
    // duplication is the point** (task 11.30). `ProjectExporter` decides what
    // to read; this is the last thing that runs before bytes exist, and it is
    // reached by every caller that ever builds an archive, including a test
    // fixture or a future path that assembles a `ProjectBackup` some other
    // way. One of these two is the decision; this one is the guarantee.
    final data = <String, Object?>{
      for (final t in syncTables)
        if (t.archiveDisclosure != ArchiveDisclosure.withheld &&
            backup.rowsFor(t.name).isNotEmpty)
          t.name: backup.rowsFor(t.name),
    };
    final dataJson = jsonEncode(data);
    archive.add(ArchiveFile.string(kDataEntry, dataJson));

    final bytes = ZipEncoder().encodeBytes(archive);
    return Uint8List.fromList(bytes);
  }

  /// Parses zip [bytes] back into a [ProjectBackup]. Throws
  /// [BackupFormatException] if the bytes aren't a valid zip, the required
  /// entries are missing, the JSON is malformed, or the manifest fails
  /// validation ([BackupManifest.fromJson]).
  static ProjectBackup decode(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw BackupFormatException('Not a readable zip archive ($e).');
    }

    final manifestFile = archive.findFile(kManifestEntry);
    if (manifestFile == null) {
      throw const BackupFormatException('Archive is missing $kManifestEntry.');
    }
    final dataFile = archive.findFile(kDataEntry);
    if (dataFile == null) {
      throw const BackupFormatException('Archive is missing $kDataEntry.');
    }

    final manifest = BackupManifest.fromJson(
      _decodeJsonObject(_contentOf(manifestFile, kManifestEntry), kManifestEntry),
    );

    final rawData = _decodeJsonObject(
      _contentOf(dataFile, kDataEntry),
      kDataEntry,
    );
    final tables = <String, List<Map<String, Object?>>>{};
    rawData.forEach((table, value) {
      if (!syncTablesByName.containsKey(table)) {
        // Ignore unknown tables rather than failing — forward-compatible with
        // a future backup that carries a table this build doesn't know.
        return;
      }
      if (value is! List) {
        throw BackupFormatException('$kDataEntry: "$table" is not a list.');
      }
      tables[table] = [
        for (final row in value)
          if (row is Map)
            row.map((k, v) => MapEntry(k as String, v))
          else
            throw BackupFormatException('$kDataEntry: "$table" has a non-object row.'),
      ];
    });

    return ProjectBackup(manifest: manifest, tables: tables);
  }

  /// The decompressed bytes of [file], as a [BackupFormatException] if they
  /// cannot be produced.
  ///
  /// **Task 11.105 — the same defect as this task's subject, at a different
  /// boundary.** `ArchiveFile.content` is where `package:archive` actually
  /// inflates the entry: `ZipDecoder.decodeBytes` defaults to `verify: false`
  /// and does not touch the payload, so a zip whose central directory survived
  /// a truncated transfer decodes without complaint and fails only here.
  /// These two reads used to be *arguments* to [_decodeJsonObject] — evaluated
  /// outside its `try` and outside [decode]'s — so a corrupt deflate stream
  /// left as a raw `FormatException: Filter error, bad data`, missed the
  /// `on BackupFormatException` branch in `data_export_screen.dart`, and
  /// reached a person as "Could not read backup" followed by a Dart exception
  /// string.
  ///
  /// **The class doc's promise — "any malformed/truncated/foreign archive
  /// throws [BackupFormatException]" — was false for the one failure the
  /// transport makes likely**, which is a `.zip` sent over WhatsApp arriving
  /// short. Measured on 2026-08-31; covered by
  /// `test/data/sync/backup_archive_corrupt_test.dart`.
  static Uint8List _contentOf(ArchiveFile file, String entry) {
    try {
      return file.content;
    } catch (e) {
      throw BackupFormatException(
        '$entry could not be read from the archive — the file is damaged or '
        'incomplete ($e).',
      );
    }
  }

  static Map<String, Object?> _decodeJsonObject(Uint8List bytes, String entry) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (e) {
      throw BackupFormatException('$entry is not valid JSON ($e).');
    }
    if (decoded is! Map<String, Object?>) {
      throw BackupFormatException('$entry is not a JSON object.');
    }
    return decoded;
  }
}

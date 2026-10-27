import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// The CSV export as one `.zip` — task 11.241.
///
/// Data Export used to write each table through its own save dialog: three
/// dialogs, then five once task 11.240 added `tags.csv` and `individuals.csv`.
/// A person exporting a season's data answered "where do you want this?" five
/// times for what is, to them, one export. Now every CSV goes into one
/// archive and the phone asks once.
///
/// **Only the packaging changed.** Each file's columns are exactly what its
/// exporter (`ObservationCsv`, `NonDetectionCsv`, `ActualTagLocationCsv`,
/// `SchemaTableCsv`) has always written; a spreadsheet or an R script that
/// read `observations.csv` reads the same file out of the zip. The entry
/// names are fixed and undated — `observations.csv`, `non_detections.csv`,
/// `truth_points.csv`, `tags.csv`, `individuals.csv`, `deployments.csv`,
/// `position_estimates.csv` (task 11.323) — so a script can name them; the
/// date is on the archive.
///
/// UTF-8 throughout, as before. Not related to `BackupArchive`, which is a
/// different format for a different purpose (a project's rows for re-import)
/// and carries a manifest this deliberately does not.
abstract final class CsvExportArchive {
  /// Encodes [files] — entry name to CSV text — as a zip.
  static Uint8List encode(Map<String, String> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      archive.add(ArchiveFile.string(entry.key, entry.value));
    }
    return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
  }

  /// Reads a zip back into entry name → text. For tests, and for the day an
  /// import wants it.
  static Map<String, String> decode(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    return {
      for (final file in archive.files)
        if (file.isFile) file.name: utf8.decode(file.readBytes()!),
    };
  }
}

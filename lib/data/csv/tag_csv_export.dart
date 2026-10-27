import 'csv_writer.dart';

import '../models/tag_fields.dart';

/// Tag roster CSV export — the write-side counterpart to [TagCsvImport],
/// using the exact same canonical header names its `_headerAliases` keys
/// recognize, so an exported file round-trips back through [TagCsvImport]
/// without relying on alias-matching. A pure formatter, like
/// [ObservationCsv]/[NonDetectionCsv] — filtering/selecting which tags to
/// export is the caller's job.
abstract final class TagCsvExport {
  static const _header = [
    'frequency_mhz',
    // Task 11.187: the tag's pulse modes. **`pulse_rate` is mode 1's rate and
    // keeps its name**, so a file exported before v12 still imports and a
    // script that reads that column still works — `pulse_modes.dart` says why
    // renaming it was not available. The import accepts
    // `pulse_mode_1_rate_bpm` as an alias for it, so the symmetric spelling
    // works on the way in even though the export uses the stored name.
    //
    // Every rate here is **beats per minute**, whatever the app is showing:
    // the seconds-per-pulse toggle is a display preference and never reaches
    // storage or an export.
    'pulse_rate',
    'pulse_mode_1_name',
    'pulse_mode_2_name',
    'pulse_mode_2_rate_bpm',
    'pulse_mode_3_name',
    'pulse_mode_3_rate_bpm',
    'pulse_pattern',
    'tag_name',
    // `date_put_on`, `date_removed` and `capture_date` left this export
    // with the columns, at schema v17 (task 11.243). They were never the
    // collar's dates; they were one deployment's, and a deployment is its own
    // row now. Exporting deployments is task 11.244's to decide.
    'status',
    'notes',
    'color_hex',
  ];

  static String export(List<TagFields> tags) {
    final rows = <List<dynamic>>[_header];
    for (final t in tags) {
      rows.add([
        t.frequencyMhz,
        t.pulseRate,
        t.pulseMode1Name,
        t.pulseMode2Name,
        t.pulseMode2RateBpm,
        t.pulseMode3Name,
        t.pulseMode3RateBpm,
        t.pulsePattern,
        t.tagName,
        t.status.db,
        t.notes,
        t.colorHex,
      ]);
    }
    return SpreadsheetSafeCsv.encode(rows);
  }
}

import 'package:csv/csv.dart';
import 'package:uuid/uuid.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import '../models/sync_meta.dart';
import '../models/tag_fields.dart';
import '../models/tag_library_entry.dart';
import '../tags/near_duplicate_tags.dart';

/// Bulk tag CSV import with a preview/dry-run before commit (design doc §8 /
/// technical doc TC:265: "Bulk tag import needs a preview/dry-run before
/// commit and must tolerate Excel UTF-8 BOM and header-name variants").
///
/// [preview] never touches the database — it only parses and validates,
/// reusing [RowValidator] (the same bound/enum checks the merge importer
/// applies) so a CSV row and a backup row are held to one standard. The
/// caller inserts [TagImportRow.entry] for whichever rows it decides to
/// commit (typically all rows with no issues), re-stamping `sync` with the
/// real device id/user at commit time — see [TagImportRow.withSync].
///
/// ## A spreadsheet lands in the tag **library** (task 11.219)
///
/// Not in a project, and not as a project's tag. A file could otherwise
/// assert that two unrelated collars are one animal — a `lineage_id` in a
/// column somebody typed — and that is a claim about the primary scientific
/// record. **A lineage is minted locally and starts here**, which is exactly
/// what §2.8 requires and what the import preview screen says in words.
/// Adding a copy to a project is a separate act the caller performs on top,
/// with the project's own role gradient in front of it.
abstract final class TagCsvImport {
  /// Canonical field -> accepted header spellings (already normalized: lower-
  /// case, non-alphanumeric runs collapsed to a single underscore). Covers the
  /// common Excel/CSV export variants (spaces, different casing, abbreviations)
  /// without trying to be exhaustive.
  static const Map<String, List<String>> _headerAliases = {
    'frequency_mhz': ['frequency_mhz', 'frequency', 'freq', 'freq_mhz', 'mhz'],
    // Task 11.187. `pulse_rate` is mode 1's rate; the symmetric spellings are
    // accepted so a file written from the mode vocabulary imports without
    // anybody having to know which column kept its old name.
    'pulse_rate': [
      'pulse_rate',
      'pulserate',
      'ppm',
      'pulses_per_minute',
      'pulse_mode_1_rate_bpm',
      'pulse_mode_1_rate',
    ],
    'pulse_mode_1_name': ['pulse_mode_1_name', 'pulse_mode_1', 'mode_1_name'],
    'pulse_mode_2_name': ['pulse_mode_2_name', 'pulse_mode_2', 'mode_2_name'],
    'pulse_mode_2_rate_bpm': ['pulse_mode_2_rate_bpm', 'pulse_mode_2_rate'],
    'pulse_mode_3_name': ['pulse_mode_3_name', 'pulse_mode_3', 'mode_3_name'],
    'pulse_mode_3_rate_bpm': ['pulse_mode_3_rate_bpm', 'pulse_mode_3_rate'],
    'pulse_pattern': ['pulse_pattern', 'pulsepattern', 'pattern'],
    'tag_name': ['tag_name', 'tagname', 'name', 'animal', 'animal_name'],
    // **`date_put_on`, `date_removed` and `capture_date` are no longer
    // recognised at all** (task 11.243, schema v17). A tag is equipment; the
    // dates belong to a `Deployments` row, and importing one from this file
    // would need an animal name column that has never existed here. A
    // roster that carries those columns imports its collars and **says
    // nothing about when they were deployed** — which is honest, because
    // this importer has nowhere to put it. Importing animals is a task of
    // its own (design §8: *"we'll want a csv import eventually"*).
    'status': ['status'],
    'notes': ['notes', 'note', 'comments', 'comment'],
    'color_hex': ['color_hex', 'colorhex', 'color', 'hex_color', 'hex'],
  };

  // `date_put_on` was required until schema v17 — it was the column that
  // made a `Tags` row a deployment. What a collar needs to exist is a
  // frequency and an identifier.
  static const _requiredFields = ['frequency_mhz', 'tag_name'];

  /// Whether this row says anything at all about the tag's pulse modes
  /// (task 11.187).
  ///
  /// **It decides between two different silences.** A file with no mode
  /// columns at all is a roster written before modes existed, or by somebody
  /// who does not use them, and it should produce the two defaults every other
  /// route produces. A file that *does* name modes and simply leaves slot 2
  /// blank is describing a one-mode collar, and adding a Mortality mode to it
  /// would contradict the roster somebody typed.
  static bool _namesAnyMode(Map<String, String?> raw) => [
    'pulse_mode_1_name',
    'pulse_mode_2_name',
    'pulse_mode_2_rate_bpm',
    'pulse_mode_3_name',
    'pulse_mode_3_rate_bpm',
  ].any((field) => raw[field] != null);

  /// Parses [csvText] and validates every row without writing anything.
  ///
  /// [autoAssignStartIndex] is the round-robin position to continue from for
  /// rows that need an auto-assigned color (missing/invalid `color_hex`) —
  /// pass the project's live tag count (e.g. via
  /// `TagRepository.nextColorHex`'s own count query) so a batch imported
  /// into a project that already has tags gets colors continuing from where
  /// those tags left off, rather than restarting at palette index 0 and
  /// reusing colors already in play. Defaults to 0 for a fresh/empty project.
  ///
  /// [existingTags] and [projectTagIds] feed the same near-duplicate check
  /// task 11.11 runs before a hand-typed tag is created ([NearDuplicateTags]),
  /// applied here per row (task 11.13). **A CSV import into a project that
  /// already holds tags is the largest single source of duplicates in the
  /// app**, and until now nothing warned about it. Same basis as 11.11:
  /// frequency first, name second, naming the existing tag that matched — and
  /// warn, never refuse, because two collars can legitimately share a nominal
  /// frequency. Pass an empty [existingTags] to skip the check entirely (e.g.
  /// a caller with no database handy, such as a unit test of parsing alone).
  static TagCsvPreview preview(
    String csvText, {
    int autoAssignStartIndex = 0,
    Iterable<TagFields> existingTags = const [],
    Set<String> projectTagIds = const {},
  }) {
    final cleaned = _stripBom(csvText);
    final rawRows = Csv().decode(cleaned);
    if (rawRows.isEmpty) {
      return const TagCsvPreview(missingRequiredColumns: _requiredFields, rows: []);
    }

    final headerRow = rawRows.first;
    final columnIndex = _mapHeaders(headerRow);
    final missing = _requiredFields.where((f) => !columnIndex.containsKey(f)).toList();
    if (missing.isNotEmpty) {
      return TagCsvPreview(missingRequiredColumns: missing, rows: const []);
    }

    // Round-robins auto-assigned colors across rows that need one (missing
    // or invalid `color_hex`) — kept purely in-memory/index-based rather
    // than DB-count-based (unlike `TagRepository.nextColorHex`), since
    // `preview` never touches the database by design. Starts from the
    // caller-supplied offset rather than always 0, so it can continue a
    // project's existing round-robin instead of restarting it.
    var autoAssignIndex = autoAssignStartIndex;
    final existing = existingTags.toList(growable: false);
    final rows = <TagImportRow>[];
    for (var i = 1; i < rawRows.length; i++) {
      final rowNumber = i + 1; // 1-based, includes the header line
      final raw = <String, String?>{
        for (final field in _headerAliases.keys)
          if (columnIndex.containsKey(field))
            field: _cell(rawRows[i], columnIndex[field]!),
      };
      final (row, usedAutoAssign) = _parseRow(
        rowNumber,
        raw,
        autoAssignIndex,
        existingTags: existing,
        projectTagIds: projectTagIds,
      );
      if (usedAutoAssign) autoAssignIndex++;
      rows.add(row);
    }
    return TagCsvPreview(missingRequiredColumns: const [], rows: rows);
  }

  static String? _cell(List<dynamic> row, int index) {
    if (index >= row.length) return null;
    final v = row[index]?.toString().trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Returns the parsed row plus whether it fell back to an auto-assigned
  /// color (so the caller can advance its round-robin index only for rows
  /// that actually used it).
  static (TagImportRow, bool) _parseRow(
    int rowNumber,
    Map<String, String?> raw,
    int autoAssignIndex, {
    required List<TagFields> existingTags,
    required Set<String> projectTagIds,
  }) {
    final issues = <String>[];

    final freqStr = raw['frequency_mhz'];
    final frequency = freqStr == null ? null : double.tryParse(freqStr);
    if (freqStr == null) {
      issues.add('frequency_mhz is required');
    } else if (frequency == null) {
      issues.add('frequency_mhz "$freqStr" is not a number');
    }

    final pulseRateStr = raw['pulse_rate'];
    final pulseRate = pulseRateStr == null ? null : double.tryParse(pulseRateStr);
    if (pulseRateStr != null && pulseRate == null) {
      issues.add('pulse_rate "$pulseRateStr" is not a number');
    }

    // Task 11.187. Same shape as `pulse_rate` above: a value that is present
    // and not a number is an error rather than a silent null, because a
    // silently dropped rate reads on screen exactly like a rate nobody
    // measured.
    double? modeRate(String field) {
      final text = raw[field];
      if (text == null) return null;
      final value = double.tryParse(text);
      if (value == null) issues.add('$field "$text" is not a number');
      return value;
    }

    final mode2Rate = modeRate('pulse_mode_2_rate_bpm');
    final mode3Rate = modeRate('pulse_mode_3_rate_bpm');

    final tagName = raw['tag_name'];
    if (tagName == null) issues.add('tag_name is required');

    // Missing status defaults to active (the common bulk-import case: a
    // roster of currently-deployed tags with no per-row status column).
    final statusRaw = raw['status'];
    final normalizedStatus =
        statusRaw == null ? 'active' : statusRaw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');
    TagStatus? status;
    try {
      status = TagStatus.fromDb(normalizedStatus);
    } catch (_) {
      issues.add('status "$statusRaw" is not one of active/recovered/lost/malfunction');
    }

    // Missing or malformed color_hex falls back to an auto-assigned palette
    // color rather than rejecting the row — consistent with the project's
    // "tolerate variance" CSV convention (a bad/missing color is cosmetic,
    // not a reason to lose an otherwise-valid tag row).
    //
    // **Finding L-15 is the half of that sentence that was wrong.** Falling
    // back is right; falling back *silently* is not. Phase 4.4 made tag colour
    // the map legend key, so a recoloured tag is a tag that reads as a
    // different animal on the Main Map — and the screen reported *"Imported N
    // tags (0 skipped)"* over it. It goes to [TagImportRow.warnings] rather
    // than to `issues` on purpose: `issues` is what makes a row invalid and
    // drops it, and dropping a tag over a bad colour would turn a cosmetic
    // problem into the data loss the fallback exists to avoid.
    final colorHexRaw = raw['color_hex'];
    final validHex = colorHexRaw != null && TagColorPalette.isValidHex(colorHexRaw);
    final colorHex =
        validHex ? colorHexRaw : TagColorPalette.colorForIndex(autoAssignIndex);
    final warnings = <String>[
      if (colorHexRaw != null && !validHex)
        'color "$colorHexRaw" is not a valid hex color — assigned $colorHex '
            'instead',
    ];

    TagLibraryEntry? entry;
    var duplicates = const <NearDuplicateTag>[];
    if (issues.isEmpty) {
      final tagId = const Uuid().v4();
      entry = TagLibraryEntry(
        tagId: tagId,
        // **Minted here, never read from the file** (§2.8). The row's own
        // fresh id is the lineage, for the reason schema v14's migration
        // gives: already unique, already unguessable, and true — nobody
        // copied this collar, somebody typed it.
        lineageId: tagId,
        frequencyMhz: frequency!,
        pulseRate: pulseRate,
        // A file that names no modes gets the two defaults — the same two a
        // tag created by hand gets, and the same two schema v12's migration
        // wrote onto every tag that already existed. A file that names some
        // gets exactly those: an import that says "mode 1: Normal" and nothing
        // else describes a one-mode collar, and inventing a Mortality mode for
        // it would be the app disagreeing with the roster somebody typed.
        pulseMode1Name:
            raw['pulse_mode_1_name'] ?? defaultPulseModeNames[0],
        pulseMode2Name: raw['pulse_mode_2_name'] ??
            (_namesAnyMode(raw) ? null : defaultPulseModeNames[1]),
        pulseMode2RateBpm: mode2Rate,
        pulseMode3Name: raw['pulse_mode_3_name'],
        pulseMode3RateBpm: mode3Rate,
        pulsePattern: raw['pulse_pattern'],
        tagName: tagName!,
        status: status!,
        notes: raw['notes'],
        colorHex: colorHex,
        sync: SyncMeta.initial(now: DateTime.now()),
      );
      // Reuse the same bound-checks the merge importer applies (VHF
      // frequency range, positive pulse rate) for one standard of validity.
      //
      // **Validated against the `Tags` spec although this row is destined
      // for the library**, and that is right rather than convenient: the
      // library's columns are a subset of `Tags`', declared once, with the
      // same bounds and the same refusal codes. A second spec for the same
      // fields is the hand-maintained list this project keeps finding. The
      // two columns the library does not have — `project_id` and
      // `copied_at` — are absent from the map, and `RowValidator` reports
      // nothing about a column that is not there.
      final rowIssues = RowValidator.validate(Tables.tags, entry.toColumns());
      issues.addAll(rowIssues.map((i) => '${i.field}: ${i.message}'));
      if (issues.isNotEmpty) {
        entry = null;
      } else {
        duplicates = NearDuplicateTags.find(
          frequencyMhz: entry.frequencyMhz,
          tagName: entry.tagName,
          existing: existingTags,
          projectTagIds: projectTagIds,
        );
      }
    }

    return (
      TagImportRow(
        rowNumber: rowNumber,
        raw: raw,
        entry: entry,
        issues: issues,
        warnings: warnings,
        duplicates: duplicates,
      ),
      !validHex,
    );
  }

  // **`_parseDate` was deleted with the three date columns** (task 11.243).
  // It parsed ISO and the `M/d/yyyy` Excel exports write, and it will be
  // wanted again the day animals or deployments get a CSV import (design §8),
  // so it is named here rather than left for somebody to rediscover: `git
  // show` this commit's parent for the body.

  static String _stripBom(String s) => s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF ? s.substring(1) : s;

  static Map<String, int> _mapHeaders(List<dynamic> headerRow) {
    final normalized = headerRow.map((h) => _normalizeHeader(h.toString())).toList();
    final index = <String, int>{};
    for (final entry in _headerAliases.entries) {
      for (final alias in entry.value) {
        final i = normalized.indexOf(alias);
        if (i != -1) {
          index[entry.key] = i;
          break;
        }
      }
    }
    return index;
  }

  static String _normalizeHeader(String raw) {
    var s = raw.trim().toLowerCase();
    s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    s = s.replaceAll(RegExp(r'^_+|_+$'), '');
    return s;
  }
}

/// The outcome of parsing one CSV data row.
class TagImportRow {
  const TagImportRow({
    required this.rowNumber,
    required this.raw,
    required this.entry,
    required this.issues,
    this.warnings = const [],
    this.duplicates = const [],
  });

  /// 1-based line number in the source file (header counted as line 1), for
  /// user-facing error display.
  final int rowNumber;
  final Map<String, String?> raw;

  /// The parsed library entry, or null if [issues] is non-empty.
  final TagLibraryEntry? entry;
  final List<String> issues;

  /// Things the parser changed about this row rather than rejecting it — a
  /// recoloured tag today (finding L-15).
  ///
  /// Separate from [issues] because the two have different consequences: an
  /// issue drops the row, a warning keeps it and says what was done to it.
  /// Folding them together would make an invalid colour cost the biologist a
  /// tag, which is the harm the fallback exists to prevent.
  final List<String> warnings;

  /// Existing tags this row's (frequency, name) resembles — task 11.13, the
  /// same [NearDuplicateTags] check task 11.11 runs before a hand-typed tag is
  /// created. Never empties the row: **warn, never refuse**, for the same
  /// reason 11.11 does — two collars can legitimately share a nominal
  /// frequency, and refusing the row would block honest field data to prevent
  /// untidiness.
  final List<NearDuplicateTag> duplicates;

  bool get isValid => entry != null;

  bool get hasDuplicates => duplicates.isNotEmpty;

  /// Re-stamps this row's tag with the real sync metadata at commit time
  /// (parse time used a placeholder `now`/null device/user, since those are
  /// only known once the user actually confirms the import).
  TagLibraryEntry withSync({
    required DateTime now,
    String? modifiedBy,
    String? deviceId,
  }) {
    final e = entry;
    if (e == null) {
      throw StateError('Row \$rowNumber has no valid tag to commit.');
    }
    return e.copyWith(
      sync: SyncMeta.initial(
        now: now,
        modifiedBy: modifiedBy,
        originDeviceId: deviceId,
      ),
    );
  }
}

/// The full result of [TagCsvImport.preview].
class TagCsvPreview {
  const TagCsvPreview({required this.missingRequiredColumns, required this.rows});

  /// Canonical field names that no header in the file matched. Non-empty
  /// means the whole file is unusable (no per-row parsing was attempted).
  final List<String> missingRequiredColumns;
  final List<TagImportRow> rows;

  bool get hasFatalHeaderError => missingRequiredColumns.isNotEmpty;
  List<TagImportRow> get validRows => rows.where((r) => r.isValid).toList();
  List<TagImportRow> get invalidRows => rows.where((r) => !r.isValid).toList();

  /// Rows the parser changed rather than rejected — see [TagImportRow.warnings]
  /// and finding L-15. Reported by the screen, because *"Imported N tags
  /// (0 skipped)"* over a silently recoloured legend key is a receipt that
  /// reads correct and is not.
  List<TagImportRow> get warnedRows =>
      rows.where((r) => r.warnings.isNotEmpty).toList();

  /// Rows that resemble a tag already in the database (task 11.13). Reported
  /// separately from [warnedRows] because the two mean different things to the
  /// person deciding: a warned row was *changed* by the parser, a duplicate row
  /// was *kept as typed* and merely looks like something that already exists.
  List<TagImportRow> get duplicateRows =>
      rows.where((r) => r.hasDuplicates).toList();
}

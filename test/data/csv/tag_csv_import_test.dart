import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/csv/tag_csv_export.dart';
import 'package:tritrack/data/csv/tag_csv_import.dart';
import 'package:tritrack/data/tags/near_duplicate_tags.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

void main() {
  group('TagCsvImport.preview — happy path', () {
    test('parses a well-formed CSV with canonical headers', () {
      const csv = 'frequency_mhz,pulse_rate,tag_name,date_put_on,status\n'
          '150.325,40,Coco,2026-01-15,active\n'
          '151.100,,Rex,2026-02-01,active\n';
      final preview = TagCsvImport.preview(csv);

      expect(preview.hasFatalHeaderError, isFalse);
      expect(preview.rows, hasLength(2));
      expect(preview.validRows, hasLength(2));
      final coco = preview.rows[0].entry!;
      expect(coco.frequencyMhz, 150.325);
      expect(coco.pulseRate, 40);
      expect(coco.tagName, 'Coco');
      expect(coco.status, TagStatus.active);
      final rex = preview.rows[1].entry!;
      expect(rex.pulseRate, isNull);
    });

    test('missing status column defaults every row to active', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,Coco,2026-01-15\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows.single.entry!.status, TagStatus.active);
    });

    test('a date_put_on column is ignored rather than refused', () {
      // **Task 11.243 removed the three date columns from this importer.** A
      // tag is equipment; when it went on an animal is a `Deployments` row,
      // and this file has never had an animal-name column to build one from.
      // A roster that still carries the column imports its collars and says
      // nothing about deployment — the honest outcome, since there is
      // nowhere to put it. Michael's own rosters may well have the column,
      // so refusing them would be the wrong direction to fail in.
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,Coco,1/5/2026\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.validRows, hasLength(1));
      expect(preview.rows.single.entry!.tagName, 'Coco');
    });

    test('and a roster with no date column at all is valid', () {
      // It was not, until this task: `date_put_on` was a required field.
      const csv = 'frequency_mhz,tag_name\n150.325,Coco\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.validRows, hasLength(1));
    });
  });

  group('TagCsvImport.preview — BOM and header-name tolerance', () {
    test('a leading UTF-8 BOM does not corrupt the first header', () {
      const bom = '﻿';
      const csv = '${bom}frequency_mhz,tag_name,date_put_on\n150.325,Coco,2026-01-15\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.hasFatalHeaderError, isFalse);
      expect(preview.validRows, hasLength(1));
    });

    test('common header spelling variants map to the canonical fields', () {
      const csv = 'Frequency (MHz),Animal Name,Deployment Date,Pulse Rate\n'
          '150.325,Coco,2026-01-15,40\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.hasFatalHeaderError, isFalse);
      final tag = preview.rows.single.entry!;
      expect(tag.frequencyMhz, 150.325);
      expect(tag.tagName, 'Coco');
      expect(tag.pulseRate, 40);
    });

    test('a status value with different casing/spacing is normalized', () {
      const csv = 'frequency_mhz,tag_name,date_put_on,status\n150.325,Coco,2026-01-15,Recovered\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows.single.entry!.status, TagStatus.recovered);
    });
  });

  group('TagCsvImport.preview — dry-run validation, nothing written', () {
    test('missing required columns is a fatal header error, no per-row parse', () {
      const csv = 'comments\nhello\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.hasFatalHeaderError, isTrue);
      // Two, not three: `date_put_on` stopped being a required column at
              // schema v17 (task 11.243) — it was what made a `Tags` row a
              // deployment, and a collar needs a frequency and an identifier.
      expect(preview.missingRequiredColumns, containsAll(['frequency_mhz', 'tag_name']));
      expect(preview.missingRequiredColumns, isNot(contains('date_put_on')));
      expect(preview.rows, isEmpty);
    });

    test('"name" alone maps to tag_name, but the frequency is still required',
        () {
      const csv = 'name,notes\nCoco,hello\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.hasFatalHeaderError, isTrue);
      expect(preview.missingRequiredColumns, containsAll(['frequency_mhz']));
      expect(preview.missingRequiredColumns, isNot(contains('tag_name')));
    });

    test('a row missing a required value is invalid but does not block other rows', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n'
          ',Coco,2026-01-15\n'
          '151.1,Rex,2026-02-01\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows, hasLength(2));
      expect(preview.rows[0].isValid, isFalse);
      expect(preview.rows[0].issues, contains('frequency_mhz is required'));
      expect(preview.rows[1].isValid, isTrue);
    });

    test('an unparseable frequency is reported, not silently coerced', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\nabc,Coco,2026-01-15\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows.single.isValid, isFalse);
      expect(preview.rows.single.issues.single, contains('not a number'));
    });

    test('an unrecognized status value is reported', () {
      const csv = 'frequency_mhz,tag_name,date_put_on,status\n150.325,Coco,2026-01-15,ludicrous\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows.single.isValid, isFalse);
      expect(preview.rows.single.issues.single, contains('status'));
    });

    test('an out-of-band frequency is caught via the reused RowValidator bound-check', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n99999,Coco,2026-01-15\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows.single.isValid, isFalse);
      expect(preview.rows.single.issues.any((i) => i.contains('frequency_mhz')), isTrue);
    });

    test('an unparseable date is no longer reported, because no date is read',
        () {
      // **Task 11.243.** This importer had three date columns and parsed
      // them; a tag is equipment now and has none, so a `date_put_on` column
      // is an unrecognised header like any other and the row is fine. That
      // is the right direction to fail in: Michael's own rosters carry the
      // column, and refusing them would be worse than ignoring it.
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,Coco,not-a-date\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows.single.isValid, isTrue);
      expect(preview.rows.single.issues, isEmpty);
    });

    test('row numbers are 1-based counting the header line', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,Coco,2026-01-15\n151.1,Rex,2026-02-01\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows[0].rowNumber, 2);
      expect(preview.rows[1].rowNumber, 3);
    });
  });

  group('TagCsvImport.preview — color_hex', () {
    test('a valid color_hex is preserved exactly', () {
      const csv = 'frequency_mhz,tag_name,date_put_on,color_hex\n'
          '150.325,Coco,2026-01-15,#123ABC\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows.single.entry!.colorHex, '#123ABC');
    });

    test('a missing color_hex column falls back to an auto-assigned color', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,Coco,2026-01-15\n';
      final preview = TagCsvImport.preview(csv);
      expect(TagColorPalette.isValidHex(preview.rows.single.entry!.colorHex), isTrue);
    });

    test('a malformed color_hex value falls back to an auto-assigned color '
        'instead of rejecting the row', () {
      const csv = 'frequency_mhz,tag_name,date_put_on,color_hex\n'
          '150.325,Coco,2026-01-15,not-a-color\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows.single.isValid, isTrue);
      expect(TagColorPalette.isValidHex(preview.rows.single.entry!.colorHex), isTrue);
    });

    test('and says so — finding L-15: a recolour is not a silent event', () {
      // Phase 4.4 made tag colour the map legend key, so a recoloured tag
      // reads as a different animal on the Main Map. The screen reported
      // "Imported N tags (0 skipped)" over it.
      const csv = 'frequency_mhz,tag_name,date_put_on,color_hex\n'
          '150.325,Coco,2026-01-15,not-a-color\n';
      final preview = TagCsvImport.preview(csv);

      expect(preview.warnedRows, hasLength(1));
      expect(preview.rows.single.warnings.single, contains('not-a-color'));
      expect(preview.rows.single.issues, isEmpty,
          reason: 'a warning must not cost the biologist the tag — that would '
              'turn a cosmetic problem into the loss the fallback prevents');
    });

    test('an absent color_hex is not a warning — nothing was overridden', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n'
          '150.325,Coco,2026-01-15\n';
      expect(TagCsvImport.preview(csv).warnedRows, isEmpty);
    });

    test('a valid color_hex is not a warning', () {
      const csv = 'frequency_mhz,tag_name,date_put_on,color_hex\n'
          '150.325,Coco,2026-01-15,#123ABC\n';
      expect(TagCsvImport.preview(csv).warnedRows, isEmpty);
    });

    test('auto-assigned colors round-robin distinctly across rows needing one', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n'
          '150.1,A,2026-01-15\n'
          '150.2,B,2026-01-15\n'
          '150.3,C,2026-01-15\n';
      final preview = TagCsvImport.preview(csv);
      final colors = preview.rows.map((r) => r.entry!.colorHex).toList();
      expect(colors, [
        TagColorPalette.colors[0],
        TagColorPalette.colors[1],
        TagColorPalette.colors[2],
      ]);
    });

    test('rows with a valid color_hex do not consume an auto-assign slot', () {
      const csv = 'frequency_mhz,tag_name,date_put_on,color_hex\n'
          '150.1,A,2026-01-15,#123456\n'
          '150.2,B,2026-01-15,\n'
          '150.3,C,2026-01-15,\n';
      final preview = TagCsvImport.preview(csv);
      final colors = preview.rows.map((r) => r.entry!.colorHex).toList();
      expect(colors[0], '#123456');
      expect(colors[1], TagColorPalette.colors[0]);
      expect(colors[2], TagColorPalette.colors[1]);
    });

    test('a header alias for color_hex is recognized', () {
      const csv = 'frequency_mhz,tag_name,date_put_on,Hex Color\n'
          '150.325,Coco,2026-01-15,#ABCDEF\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows.single.entry!.colorHex, '#ABCDEF');
    });

    test('autoAssignStartIndex continues the round-robin instead of restarting at 0 '
        '(task 9.5: importing into a project that already has tags)', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n'
          '150.1,A,2026-01-15\n'
          '150.2,B,2026-01-15\n'
          '150.3,C,2026-01-15\n';
      final preview = TagCsvImport.preview(csv, autoAssignStartIndex: 2);
      final colors = preview.rows.map((r) => r.entry!.colorHex).toList();
      expect(colors, [
        TagColorPalette.colors[2],
        TagColorPalette.colors[3],
        TagColorPalette.colors[4],
      ]);
    });

    test('autoAssignStartIndex wraps around the palette exactly like index 0 does', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,Coco,2026-01-15\n';
      final preview = TagCsvImport.preview(
        csv,
        autoAssignStartIndex: TagColorPalette.colors.length,
      );
      expect(preview.rows.single.entry!.colorHex, TagColorPalette.colors[0]);
    });

    test('a valid explicit color_hex still does not consume an auto-assign slot '
        'when combined with a non-zero autoAssignStartIndex', () {
      const csv = 'frequency_mhz,tag_name,date_put_on,color_hex\n'
          '150.1,A,2026-01-15,#123456\n'
          '150.2,B,2026-01-15,\n'
          '150.3,C,2026-01-15,\n';
      final preview = TagCsvImport.preview(csv, autoAssignStartIndex: 5);
      final colors = preview.rows.map((r) => r.entry!.colorHex).toList();
      expect(colors[0], '#123456');
      expect(colors[1], TagColorPalette.colors[5]);
      expect(colors[2], TagColorPalette.colors[6]);
    });

    test('default autoAssignStartIndex of 0 keeps prior no-arg-call behavior unchanged', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,Coco,2026-01-15\n';
      final withDefault = TagCsvImport.preview(csv);
      final withExplicitZero = TagCsvImport.preview(csv, autoAssignStartIndex: 0);
      expect(withDefault.rows.single.entry!.colorHex, withExplicitZero.rows.single.entry!.colorHex);
      expect(withDefault.rows.single.entry!.colorHex, TagColorPalette.colors[0]);
    });
  });

  group('TagCsvExport round-trip', () {
    test('export then import preserves colors exactly for valid hex values', () {
      final tags = [
        sampleTag(id: 'tag-1', colorHex: TagColorPalette.colors[3]),
        sampleTag(id: 'tag-2', colorHex: TagColorPalette.colors[5])
            .copyWith(tagName: 'Rex'),
      ];
      final csv = TagCsvExport.export(tags);
      final preview = TagCsvImport.preview(csv);

      expect(preview.validRows, hasLength(2));
      expect(preview.rows[0].entry!.colorHex, TagColorPalette.colors[3]);
      expect(preview.rows[1].entry!.colorHex, TagColorPalette.colors[5]);
    });
  });

  group('TagCsvImport.preview — duplicate warnings (task 11.13)', () {
    test('a frequency collision warns and names the existing tag', () {
      final existing = [sampleTag(id: 'tag-1', tagName: 'Coco', frequencyMhz: 150.325)];
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,Beans,2026-01-15\n';
      final preview = TagCsvImport.preview(
        csv,
        existingTags: existing,
        projectTagIds: {'tag-1'},
      );

      final row = preview.rows.single;
      expect(row.isValid, isTrue);
      expect(row.hasDuplicates, isTrue);
      expect(row.duplicates.single.existing.tagId, 'tag-1');
      expect(row.duplicates.single.matched, contains(TagMatchKind.frequency));
      expect(preview.duplicateRows, [row]);
    });

    test('a name collision (different frequency) warns too', () {
      final existing = [sampleTag(id: 'tag-1', tagName: 'Coco', frequencyMhz: 150.325)];
      const csv = 'frequency_mhz,tag_name,date_put_on\n151.100,Coco,2026-01-15\n';
      final preview = TagCsvImport.preview(csv, existingTags: existing);

      expect(preview.rows.single.duplicates.single.matched, contains(TagMatchKind.name));
    });

    test('the import proceeds — warn, never refuse', () {
      final existing = [sampleTag(id: 'tag-1', tagName: 'Coco', frequencyMhz: 150.325)];
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,Beans,2026-01-15\n';
      final preview = TagCsvImport.preview(csv, existingTags: existing);

      expect(preview.validRows, hasLength(1));
      expect(preview.rows.single.entry, isNotNull);
    });

    test('no warning fires for a genuinely distinct tag', () {
      final existing = [sampleTag(id: 'tag-1', tagName: 'Coco', frequencyMhz: 150.325)];
      const csv = 'frequency_mhz,tag_name,date_put_on\n151.100,Rex,2026-02-01\n';
      final preview = TagCsvImport.preview(csv, existingTags: existing);

      expect(preview.rows.single.hasDuplicates, isFalse);
      expect(preview.duplicateRows, isEmpty);
    });

    test('warns on exactly the overlapping rows in a larger batch and no others', () {
      final existing = [
        sampleTag(id: 'tag-1', tagName: 'Coco', frequencyMhz: 150.325),
        sampleTag(id: 'tag-2', tagName: 'Rex', frequencyMhz: 151.100),
      ];
      final buffer = StringBuffer('frequency_mhz,tag_name,date_put_on\n');
      // Rows 2 and 3 collide with existing tags; the rest are distinct.
      buffer.writeln('150.325,Beans,2026-01-15'); // row 2: frequency collision
      buffer.writeln('152.000,Rex,2026-01-16'); // row 3: name collision
      for (var i = 0; i < 5; i++) {
        buffer.writeln('${153.0 + i},Animal$i,2026-01-${17 + i}'); // distinct
      }
      final preview = TagCsvImport.preview(buffer.toString(), existingTags: existing);

      expect(preview.rows, hasLength(7));
      expect(preview.duplicateRows.map((r) => r.rowNumber), [2, 3]);
    });

    test('an invalid row is not checked for duplicates', () {
      final existing = [sampleTag(id: 'tag-1', tagName: 'Coco', frequencyMhz: 150.325)];
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,,2026-01-15\n';
      final preview = TagCsvImport.preview(csv, existingTags: existing);

      final row = preview.rows.single;
      expect(row.isValid, isFalse);
      expect(row.hasDuplicates, isFalse);
    });

    test('with no existing tags passed, nothing warns', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,Coco,2026-01-15\n';
      final preview = TagCsvImport.preview(csv);
      expect(preview.rows.single.hasDuplicates, isFalse);
    });
  });

  group('TagImportRow.withSync', () {
    test('re-stamps sync metadata at commit time', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n150.325,Coco,2026-01-15\n';
      final row = TagCsvImport.preview(csv).rows.single;
      final now = DateTime.utc(2026, 7, 17);
      final tag = row.withSync(now: now, modifiedBy: 'user-1', deviceId: 'device-A');
      expect(tag.sync.createdAt, now);
      expect(tag.sync.lastModifiedBy, 'user-1');
      expect(tag.sync.originDeviceId, 'device-A');
    });

    test('throws if the row has no valid tag', () {
      const csv = 'frequency_mhz,tag_name,date_put_on\n,Coco,2026-01-15\n';
      final row = TagCsvImport.preview(csv).rows.single;
      expect(() => row.withSync(now: DateTime.now()), throwsStateError);
    });
  });
}

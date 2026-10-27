import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/csv/non_detection_csv.dart';
import 'package:tritrack/data/csv/observation_csv.dart';
import 'package:tritrack/data/models/tag_version.dart';

import '../fixtures.dart';

void main() {
  group('ObservationCsv.export', () {
    test('header plus one row, with tag/observer names resolved', () {
      final obs = sampleObservation();
      final tag = sampleTag();
      final user = sampleUser();

      final csvText = ObservationCsv.export(
        [obs],
        tagsById: {tag.tagId: tag},
        usersById: {user.userId: user},
        recordedStates: {
          obs.observationId: RecordedTagState(
            tag: tag,
            version: sampleTagVersion(),
          ),
        },
      );

      final rows = Csv().decode(csvText);
      expect(rows, hasLength(2));
      expect(rows[0].first, 'observation_id');
      final row = rows[1];
      final header = rows[0].map((h) => h.toString()).toList();
      Object? col(String name) => row[header.indexOf(name)];

      expect(col('observation_id'), obs.observationId);
      expect(col('tag_name'), 'Coco');
      expect(col('tag_frequency_mhz'), '150.325');
      expect(col('tag_values_recorded'), 'yes');
      expect(col('tag_current_name'), 'Coco');
      expect(col('observer_name'), 'Sam Ranger');
      expect(col('latitude'), '35.19');
      expect(col('signal_strength'), 'medium');
      expect(col('notes'), 'clear signal');
    });

    // **Task 11.32's export acceptance, stated as the harm.** A spreadsheet
    // made this morning and one made after somebody renames and re-tunes the
    // tag have to agree about the same bearing.
    test('a rename and a re-tune do not change what an earlier bearing '
        'exports as', () {
      final obs = sampleObservation();
      final asRecorded = sampleTagVersion();

      String exportWith(dynamic tag) => ObservationCsv.export(
            [obs],
            tagsById: {tag.tagId: tag},
            usersById: {},
            recordedStates: {
              obs.observationId:
                  RecordedTagState(tag: tag, version: asRecorded),
            },
          );

      List<Object?> rowOf(String csv) => Csv().decode(csv)[1];
      final header =
          Csv().decode(exportWith(sampleTag()))[0].map((h) => h.toString()).toList();
      Object? col(List<Object?> row, String name) => row[header.indexOf(name)];

      final today = rowOf(exportWith(sampleTag()));
      final afterEdit = rowOf(
        exportWith(sampleTag(tagName: 'F21', frequencyMhz: 150.51)),
      );

      expect(col(afterEdit, 'tag_name'), col(today, 'tag_name'));
      expect(
        col(afterEdit, 'tag_frequency_mhz'),
        col(today, 'tag_frequency_mhz'),
        reason: 'the bearing was taken at 150.325 whatever the tag says now',
      );
      // And the drift is visible rather than hidden — two columns, not one
      // reconciled number.
      expect(col(afterEdit, 'tag_current_name'), 'F21');
      expect(col(afterEdit, 'tag_current_frequency_mhz'), '150.51');
    });

    test('a bearing that does not know exports empty cells, not the tag\'s '
        'present-day values', () {
      // The no-backfill rule at the surface a person actually reads. An
      // observation with no version — one recorded before schema v9, or pasted
      // from a share payload — must not silently adopt today's frequency.
      final obs = sampleObservation(tagVersionId: null);
      final tag = sampleTag();
      final csvText = ObservationCsv.export(
        [obs],
        tagsById: {tag.tagId: tag},
        usersById: {},
        recordedStates: {
          obs.observationId: RecordedTagState(tag: tag, version: null),
        },
      );
      final rows = Csv().decode(csvText);
      final header = rows[0].map((h) => h.toString()).toList();
      final row = rows[1];
      expect(row[header.indexOf('tag_name')], anyOf(isNull, ''));
      expect(row[header.indexOf('tag_frequency_mhz')], anyOf(isNull, ''));
      expect(row[header.indexOf('tag_values_recorded')], 'no');
      // …while the current values are still there, so the row is usable.
      expect(row[header.indexOf('tag_current_name')], 'Coco');
    });

    test('a caller that passes no recorded states gets "no", never a silent '
        'fallback to the tag row', () {
      // The failure mode this guards is a new export call site forgetting the
      // argument and quietly reintroducing the whole defect.
      final obs = sampleObservation();
      final tag = sampleTag();
      final csvText = ObservationCsv.export(
        [obs],
        tagsById: {tag.tagId: tag},
        usersById: {},
      );
      final rows = Csv().decode(csvText);
      final header = rows[0].map((h) => h.toString()).toList();
      expect(rows[1][header.indexOf('tag_values_recorded')], 'no');
      expect(rows[1][header.indexOf('tag_name')], anyOf(isNull, ''));
    });

    test('falls back to raw ids when tag/user lookups are absent', () {
      final obs = sampleObservation();
      final csvText = ObservationCsv.export([obs], tagsById: {}, usersById: {});
      final rows = Csv().decode(csvText);
      final header = rows[0].map((h) => h.toString()).toList();
      final row = rows[1];
      expect(row[header.indexOf('tag_current_name')], obs.tagId);
      expect(row[header.indexOf('observer_name')], obs.userId);
    });

    test('null optional fields export as empty cells, not "null" strings', () {
      final obs = sampleMinimalObservation();
      final csvText = ObservationCsv.export([obs], tagsById: {}, usersById: {});
      final rows = Csv().decode(csvText);
      final header = rows[0].map((h) => h.toString()).toList();
      final row = rows[1];
      expect(row[header.indexOf('magnetic_bearing')], anyOf(isNull, ''));
      expect(row[header.indexOf('notes')], anyOf(isNull, ''));
    });

    /// **Task 11.193 — three answers, three cells, and an empty one is not
    /// "no".**
    ///
    /// This column exists so somebody can look through a season for the
    /// collars that were sounding wrong. An empty cell means nobody was asked
    /// — a bearing recorded before the control existed, or a record type with
    /// no signal in it — and reading that as "no" is the difference between a
    /// failing collar found and one missed.
    test('the irregular-signal flag exports yes, no, or nothing at all', () {
      final tag = sampleTag();
      final user = sampleUser();
      final rows = Csv().decode(ObservationCsv.export(
        [
          sampleObservation(id: 'flagged', signalIrregular: true),
          sampleObservation(id: 'clear', signalIrregular: false),
          sampleObservation(id: 'unasked'),
        ],
        tagsById: {tag.tagId: tag},
        usersById: {user.userId: user},
      ));
      final header = rows[0].map((h) => h.toString()).toList();
      final column = header.indexOf('signal_irregular');
      expect(column, isNot(-1));
      expect(rows[1][column], 'yes');
      expect(rows[2][column], 'no');
      expect(
        rows[3][column],
        anyOf(isNull, ''),
        reason: 'A bearing nobody was asked about exports an empty cell. '
            '"no" there would be a claim the observer never made, in the one '
            'column a person reads to find failing collars.',
      );
    });

    // **Task 11.67 — `altitude_agl` is back, because a person can now set
    // it.** Task 11.30 removed it while every row said a zero nobody had
    // measured. Now zero means on the ground and a non-zero value is what
    // somebody typed for a receiver in an aircraft, and both export.
    test('the receiver height above ground exports, in metres, and zero '
        'means on the ground', () {
      final tag = sampleTag();
      final user = sampleUser();
      // The fixture carries 1.5 m, a held antenna; the on-foot row is the
      // model's own default, which is what the Record screen writes on foot.
      final onFoot = sampleObservation().copyWith(altitudeAgl: 0);
      final airborne =
          sampleObservation(id: 'obs-air').copyWith(altitudeAgl: 300);
      final rows = Csv().decode(ObservationCsv.export(
        [onFoot, airborne],
        tagsById: {tag.tagId: tag},
        usersById: {user.userId: user},
      ));
      final header = rows[0].map((h) => h.toString()).toList();
      final column = header.indexOf('altitude_agl_m');
      expect(column, greaterThan(header.indexOf('elevation_m')));
      expect(rows[1][column], anyOf(0, 0.0, '0', '0.0'));
      expect(rows[2][column], anyOf(300, 300.0, '300', '300.0'));
    });

    test('the non-detection export carries the same column', () {
      final tag = sampleTag();
      final user = sampleUser();
      final rows = Csv().decode(NonDetectionCsv.export(
        [sampleNonDetection().copyWith(altitudeAgl: 300)],
        tagsById: {tag.tagId: tag},
        usersById: {user.userId: user},
      ));
      final header = rows[0].map((h) => h.toString()).toList();
      expect(rows[1][header.indexOf('altitude_agl_m')],
          anyOf(300, 300.0, '300', '300.0'));
    });

    test('an empty observation list exports just the header', () {
      final csvText = ObservationCsv.export([], tagsById: {}, usersById: {});
      final rows = Csv().decode(csvText);
      expect(rows, hasLength(1));
    });
  });
}

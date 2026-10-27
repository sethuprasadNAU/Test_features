import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **Task 11.136 — a range that says why it refused a row.**
///
/// ## What was true before, said plainly
///
/// A latitude of 999 or a frequency outside the VHF window was refused, and
/// the person holding that record was told *"the server would not store this
/// record, and it did not say which part of it was the problem"* — task
/// 11.122's honest default. That was correct rather than broken: the range
/// checks were twenty-nine column checks written inline in
/// `RowValidator.validate`,
/// and **an inline call has no declaration to read a code off.**
///
/// The fix was not to type a code at each of the twenty-nine sites — that is
/// the hand-maintained list task 11.88 ruled out, and it would have been wrong
/// the first time somebody added a column. It was to move the judgement onto
/// the column, where [TextBound] already lives, and let the code fall out of
/// it.
void main() {
  test('every numeric column declares what bounds it', () {
    assertEveryNumericColumnIsBounded();
  });

  group('the bound decides which limit was broken, and the limit names the '
      'code', () {
    test('every limit carries a code, and no two share one', () {
      final codes = NumericLimit.values.map((l) => l.violationCode).toList();
      expect(codes, hasLength(NumericLimit.values.length));
      expect(codes.toSet(), hasLength(codes.length));
    });

    test('no numeric code is also a text shape code, so a sentence written '
        'for one cannot be reached by the other', () {
      final numeric = NumericLimit.values.map((l) => l.violationCode).toSet();
      final text = {
        for (final shape in TextShape.values)
          if (shape.violationCode != null) shape.violationCode!,
      };
      expect(numeric.intersection(text), isEmpty);
    });

    test('a bound answers which limit a value broke', () {
      const latitude = NumericBound.latitude;
      expect(latitude.violatedBy(0), isNull);
      expect(latitude.violatedBy(-90), isNull, reason: 'the floor is included');
      expect(latitude.violatedBy(90), isNull, reason: 'the ceiling is included');
      expect(latitude.violatedBy(-90.1), NumericLimit.belowMinimum);
      expect(latitude.violatedBy(90.1), NumericLimit.aboveMaximum);
      expect(latitude.violatedBy(double.nan), NumericLimit.notARealNumber);
      expect(
        latitude.violatedBy(double.infinity),
        NumericLimit.notARealNumber,
        reason: 'an infinity is above every ceiling, but the useful thing to '
            'say about it is that it is not a measurement',
      );
    });

    test('an exclusive minimum refuses its own value', () {
      const positive = NumericBound.positiveMeasurement;
      expect(positive.violatedBy(0), NumericLimit.belowMinimum);
      expect(positive.violatedBy(-1), NumericLimit.belowMinimum);
      expect(positive.violatedBy(0.0001), isNull);
      expect(positive.violatedBy(1e9), isNull, reason: 'no ceiling declared');
    });

    test('an unbounded column is still not allowed to hold a non-number', () {
      // **The half of finding M-1 that is easiest to lose in a change like
      // this.** `NumericBound.unbounded` is a decision that no *range* is
      // honest, not a decision that anything goes: NaN is unordered, so it
      // passes every comparison, and a NaN elevation silently poisons any mean
      // or bounding box computed over the dataset.
      expect(
        NumericBound.unbounded.violatedBy(double.nan),
        NumericLimit.notARealNumber,
      );
      expect(NumericBound.unbounded.violatedBy(-1e30), isNull);

      final issues = RowValidator.validate(Tables.observations, {
        'observation_id': 'obs-1',
        'project_id': 'proj-1',
        'elevation': double.nan,
      });
      expect(issues.single.field, 'elevation');
      expect(issues.single.code, RowIssueCode.numberNotARealNumber);
    });
  });

  group('the numbers themselves did not change', () {
    // The regression bar. Moving a judgement from a call site to a
    // declaration is exactly the moment it can be transcribed wrong, and a
    // wrong bound is invisible: it refuses rows that used to sync, or admits
    // ones that never did.
    test('the frequency window is the one the technical doc asked for', () {
      expect(NumericBound.frequencyMhz.min, 30);
      expect(NumericBound.frequencyMhz.max, 1000);
    });

    test('degrees, latitude and longitude are unchanged', () {
      expect(NumericBound.degrees.min, 0);
      expect(NumericBound.degrees.max, 360);
      expect(NumericBound.latitude.min, -90);
      expect(NumericBound.latitude.max, 90);
      expect(NumericBound.longitude.min, -180);
      expect(NumericBound.longitude.max, 180);
    });

    test('every column that was range-checked inline still is', () {
      // Named one by one, because "twenty-nine checks moved" is the kind of
      // claim that is satisfied by twenty-six.
      const expected = <String, Map<String, NumericBound>>{
        Tables.projects: {
          'bbox_min_lat': NumericBound.latitude,
          'bbox_max_lat': NumericBound.latitude,
          'bbox_min_lon': NumericBound.longitude,
          'bbox_max_lon': NumericBound.longitude,
          // The thirtieth, added by task 11.158: it was `unbounded`, and that
          // claim was false in one direction. See that task's group below.
          'triangulation_window_minutes': NumericBound.positiveMeasurement,
        },
        // Task 11.187 added the two extra pulse-mode rates on each of these
        // two tables. They take the same bound `pulse_rate` has, and for the
        // same reason: a rate of zero is not a slow collar, it is a missing
        // measurement. Slot 1's rate *is* `pulse_rate` — see
        // `pulse_modes.dart`.
        Tables.tags: {
          'frequency_mhz': NumericBound.frequencyMhz,
          'pulse_rate': NumericBound.positiveMeasurement,
          'pulse_mode_2_rate_bpm': NumericBound.positiveMeasurement,
          'pulse_mode_3_rate_bpm': NumericBound.positiveMeasurement,
        },
        Tables.tagVersions: {
          'frequency_mhz': NumericBound.frequencyMhz,
          'pulse_rate': NumericBound.positiveMeasurement,
          'pulse_mode_2_rate_bpm': NumericBound.positiveMeasurement,
          'pulse_mode_3_rate_bpm': NumericBound.positiveMeasurement,
        },
        Tables.observations: {
          'latitude': NumericBound.latitude,
          'longitude': NumericBound.longitude,
          'position_accuracy_m': NumericBound.positiveMeasurement,
          'magnetic_bearing': NumericBound.degrees,
          'true_north_bearing': NumericBound.degrees,
          'magnetic_bearing_start': NumericBound.degrees,
          'magnetic_bearing_end': NumericBound.degrees,
          'true_north_bearing_start': NumericBound.degrees,
          'true_north_bearing_end': NumericBound.degrees,
          'bearing_uncertainty': NumericBound.positiveMeasurement,
          // Task 11.187: a slot number, 1..maxPulseModes — not a measurement,
          // which is why it has a bound of its own rather than borrowing one.
          'pulse_mode': NumericBound.pulseModeSlot,
          // Task 11.193: a stored yes/no, 0 or 1. SQLite has no boolean, so
          // the bound is what makes this column a flag rather than a counter
          // that happens to hold small numbers. NULL is a third answer and no
          // bound speaks about it — see the column's own declaration.
          'signal_irregular': NumericBound.flag,
        },
        Tables.nonDetections: {
          'latitude': NumericBound.latitude,
          'longitude': NumericBound.longitude,
          'position_accuracy_m': NumericBound.positiveMeasurement,
        },
        Tables.estimatedPositions: {
          'latitude': NumericBound.latitude,
          'longitude': NumericBound.longitude,
          'semi_major_axis': NumericBound.positiveMeasurement,
          'semi_minor_axis': NumericBound.positiveMeasurement,
          'rotation_angle': NumericBound.degrees,
        },
        Tables.actualTagLocations: {
          'latitude': NumericBound.latitude,
          'longitude': NumericBound.longitude,
          'uncertainty_radius': NumericBound.positiveMeasurement,
        },
      };
      expected.forEach((table, columns) {
        final spec = tableSpecsByName[table]!;
        columns.forEach((name, bound) {
          expect(
            spec.columns.firstWhere((c) => c.name == name).numericBound,
            same(bound),
            reason: '$table.$name lost the bound it had before task 11.136',
          );
        });
      });

      // **The count, asserted rather than written in a report.** Twenty-nine
      // is what the inline checks came to, counted as (table, column) pairs —
      // `latLon()` was one call and two columns, and the tag helper was one
      // call on each of two tables. A further column appearing here is either
      // a new bound somebody added (say so, and change this number) or one of
      // the twenty-nine landing on the wrong column.
      //
      // 30 → 35 in task 11.187: four pulse-mode rate columns (two each on
      // `Tags` and `Tag_Versions`) and `Observations.pulse_mode`.
      // 35 → 36 in task 11.193: `Observations.signal_irregular`.
      // **`syncColumns` is excluded, and that exclusion is itself asserted
      // below.** `revision` gained a floor in task 11.158 and it is one
      // `ColumnSpec` spread into every table, so counting it here would add a
      // row per table and turn a bar about *domain* columns into a count of
      // tables. The group at the end of this file checks the sync column's
      // own bound directly, once.
      final ranged = [
        for (final spec in tableSpecs)
          for (final column in spec.columns)
            if (column.numericBound != null &&
                !identical(column.numericBound, NumericBound.unbounded) &&
                !syncColumns.any((c) => identical(c, column)))
              '${spec.name}.${column.name}',
      ];
      expect(
        ranged,
        hasLength(36),
        reason: 'the ranged columns are $ranged',
      );
      expect(
        ranged.toSet(),
        {
          for (final entry in expected.entries)
            for (final name in entry.value.keys) '${entry.key}.$name',
        },
        reason: 'a column gained or lost a range without this list moving',
      );
    });

    test('a column nobody bounded is declared unbounded rather than left '
        'undeclared', () {
      const unbounded = {
        Tables.observations: ['elevation', 'altitude_agl', 'receiver_gain',
            'magnetic_declination'],
      };
      unbounded.forEach((table, columns) {
        for (final name in columns) {
          expect(
            tableSpecsByName[table]!.columns
                .firstWhere((c) => c.name == name)
                .numericBound,
            same(NumericBound.unbounded),
            reason: '$table.$name has no honest range, and says so',
          );
        }
      });

      // **Task 11.158 shrank this list from six columns to four**, and the
      // two that left are named here so their departure is a decision on the
      // record rather than an absence. `revision` and
      // `triangulation_window_minutes` each had a floor nobody had written
      // down; `unbounded` is a claim that no honest range exists, and for
      // these two it was false below zero.
      for (final bound in [
        syncColumns.firstWhere((c) => c.name == 'revision').numericBound,
        tableSpecsByName[Tables.projects]!.columns
            .firstWhere((c) => c.name == 'triangulation_window_minutes')
            .numericBound,
      ]) {
        expect(bound, isNot(same(NumericBound.unbounded)));
        expect(bound!.min, 0);
        expect(bound.max, isNull, reason: 'a floor was added, not a ceiling');
      }
    });
  });
}

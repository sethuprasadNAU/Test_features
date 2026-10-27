import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **The declaration that says which `Tags` columns hold a pulse mode, and the
/// guard that keeps it true — task 11.187.**
///
/// `pulseModeColumns` is the one place that knows slot 1's rate lives in the
/// column called `pulse_rate` while slots 2 and 3 have columns named after
/// themselves. That asymmetry is a scar from the schema's history — renaming a
/// shipped column costs a `schemaMajorVersion` bump and strands every device in
/// the field — and it is survivable **only** because one declaration owns it
/// and everything else derives.
///
/// So the two things worth a test are: that the declaration matches the schema,
/// and that a violation of it fails loudly rather than quietly reopening the
/// defect task 11.32 closed.
void main() {
  group('the declaration matches the schema', () {
    test('the real schema passes', () {
      expect(assertPulseModeColumnsAreVersioned, returnsNormally);
    });

    test('there are exactly as many slots as the maximum says', () {
      expect(pulseModeColumns, hasLength(maxPulseModes));
      expect(
        pulseModeColumns.map((m) => m.slot),
        [for (var i = 1; i <= maxPulseModes; i++) i],
      );
    });

    test("slot 1's rate is the column that was already there", () {
      // The whole reason no value moves in schema v12's migration, and the
      // reason a `Tag_Versions` row written last season still means what it
      // meant. If this ever changes, every historical rate has to move with it.
      expect(pulseModeColumns.first.rateColumn, 'pulse_rate');
    });

    test('every mode column really is a column of Tags', () {
      final actual = {
        for (final c in tableSpecsByName[Tables.tags]!.columns) c.name,
      };
      for (final mode in pulseModeColumns) {
        expect(actual, contains(mode.nameColumn));
        expect(actual, contains(mode.rateColumn));
      }
    });

    test('the v12 column list is exactly the mode columns that are new', () {
      // The migration on each side is written out by hand — a shipped
      // migration describes the change as it was made — so this is what stops
      // the three lists disagreeing about which columns v12 adds.
      final declared = {
        for (final mode in pulseModeColumns) ...[
          mode.nameColumn,
          mode.rateColumn,
        ],
      };
      expect(
        pulseModeColumnsAddedInV12.toSet(),
        declared.difference({'pulse_rate'}),
      );
    });
  });

  // **Proving the guard can fail**, in both directions, by handing it a
  // doctored declaration rather than by editing the schema and putting it
  // back. A guard nobody has seen fail is not a guard.
  group('the guard refuses a declaration that has drifted', () {
    test('a mode column the tag table does not have fails', () {
      final doctored = [
        for (final column in tableSpecsByName[Tables.tags]!.columns)
          if (column.name != 'pulse_mode_3_rate_bpm') column,
      ];
      expect(
        () => assertPulseModeColumnsAreVersioned(tagColumns: doctored),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('pulse_mode_3_rate_bpm'),
              contains('drifted'),
            ),
          ),
        ),
      );
    });

    test('a mode column classified as anything but measurement context fails',
        () {
      // The quieter and worse direction. A mode read live off the tag row
      // would rename itself on every bearing ever recorded against it — task
      // 11.32's harm, reopened one column at a time, with nothing on screen
      // saying so.
      final doctored = {
        ...tagColumnKinds,
        'pulse_mode_2_name': TagColumnKind.display,
      };
      expect(
        () => assertPulseModeColumnsAreVersioned(kinds: doctored),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('pulse_mode_2_name'),
              contains('measurementContext'),
            ),
          ),
        ),
      );
    });
  });

  group('the legacy signal type is a projection, and it is read as one', () {
    test('a record with no stored slot is read through signal_type', () {
      // Every bearing written before schema v12. Nothing is backfilled — the
      // mapping happens here, on read.
      expect(pulseModeSlotOf(legacy: SignalType.regularPulse), 1);
      expect(pulseModeSlotOf(legacy: SignalType.mortalitySignal), 2);
    });

    test('a stored slot wins, which is what makes the projection safe to be '
        'lossy about a third mode', () {
      for (final legacy in SignalType.values) {
        expect(pulseModeSlotOf(storedSlot: 3, legacy: legacy), 3);
      }
    });

    test('the projection written on a new row', () {
      expect(SignalType.forPulseModeSlot(1), SignalType.regularPulse);
      expect(SignalType.forPulseModeSlot(2), SignalType.mortalitySignal);
      // Slot 3 has no honest value in a two-valued field. `regular_pulse` is
      // the correct answer to the only question that field can ask — *was this
      // the tag's second, historically mortality, slot?* — and nothing in this
      // build reads it when `pulse_mode` is present.
      expect(SignalType.forPulseModeSlot(3), SignalType.regularPulse);
      // Total, including for a record with no tag and therefore no modes: the
      // column is NOT NULL, so there is no branch that may decline to answer.
      expect(SignalType.forPulseModeSlot(null), SignalType.regularPulse);
    });

    test('the round trip holds for the two slots the legacy field can express',
        () {
      for (final slot in [1, 2]) {
        expect(
          pulseModeSlotOf(legacy: SignalType.forPulseModeSlot(slot)),
          slot,
        );
      }
    });
  });

  group('the slot bound on the wire', () {
    test('it admits every slot and refuses the one after', () {
      for (var slot = 1; slot <= maxPulseModes; slot++) {
        expect(NumericBound.pulseModeSlot.violatedBy(slot.toDouble()), isNull);
      }
      expect(
        NumericBound.pulseModeSlot.violatedBy(0),
        NumericLimit.belowMinimum,
      );
      expect(
        NumericBound.pulseModeSlot.violatedBy(maxPulseModes + 1),
        NumericLimit.aboveMaximum,
      );
    });

    test('a row naming a slot that does not exist is refused', () {
      final issues = RowValidator.validate(Tables.observations, {
        'observation_id': 'obs-1',
        'project_id': 'project-1',
        'pulse_mode': 4,
      });
      expect(issues.map((i) => i.field), contains('pulse_mode'));
    });
  });
}

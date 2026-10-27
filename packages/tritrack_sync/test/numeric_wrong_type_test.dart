import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **Task 11.158 — a latitude of "north".**
///
/// ## What was true before, said plainly
///
/// A numeric column holding something that is not a number at all was
/// **refused by nothing.** `{"latitude": "north"}` validated and was stored,
/// because `RowValidator._num` answered null for it and a null was skipped —
/// so the range check never ran and no issue was raised. The text arm had
/// refused its own version of this since task 11.124
/// ([RowIssueCode.textWrongType]); the numeric arm had no counterpart.
///
/// Task 11.136 built the machinery that makes the code derivable — the bound
/// is on the column, and the limit the bound names carries the code — and
/// deliberately did not close this, because closing it newly refuses rows
/// that sync today and nobody had counted them. They are counted now, and the
/// count is zero: see this task's comms entry.
///
/// ## The one leniency that is kept on purpose
///
/// A **numeric string** — `"42"` — is still accepted, because `_num` parses
/// it and always has. That is a wire-format kindness rather than a hole: the
/// value is a number, it is read as one, and the declared range is then
/// applied to it exactly as if it had arrived unquoted. What is refused is a
/// value that **cannot be read as a number at all**.
void main() {
  group('a numeric column refuses a value that is not a number', () {
    test('a latitude of "north" is refused, and the refusal names latitude',
        () {
      final issues = RowValidator.validate(Tables.observations, {
        'observation_id': 'obs-1',
        'project_id': 'proj-1',
        'latitude': 'north',
      });
      expect(issues, hasLength(1));
      expect(issues.single.field, 'latitude');
      expect(issues.single.code, RowIssueCode.numberWrongType);
    });

    test('every shape of non-number is refused, not just a string', () {
      // A hand-crafted push is JSON, so a numeric column can arrive holding a
      // bool, an array or an object as easily as a word. Before this task all
      // four were stored.
      for (final value in <Object>[
        'north',
        true,
        <String>['90'],
        <String, Object?>{'value': 90},
      ]) {
        final issues = RowValidator.validate(Tables.observations, {
          'observation_id': 'obs-1',
          'project_id': 'proj-1',
          'latitude': value,
        });
        expect(
          issues.map((i) => i.code),
          [RowIssueCode.numberWrongType],
          reason: 'a latitude of $value (${value.runtimeType}) was admitted',
        );
      }
    });

    test('an unbounded numeric column refuses it too', () {
      // `NumericBound.unbounded` is a decision that no *range* is honest, not
      // a decision that anything goes — the same point finding M-1 made about
      // NaN, one type further out.
      final issues = RowValidator.validate(Tables.observations, {
        'observation_id': 'obs-1',
        'project_id': 'proj-1',
        'elevation': 'high',
      });
      expect(issues.single.field, 'elevation');
      expect(issues.single.code, RowIssueCode.numberWrongType);
    });

    test('a numeric string is still read as its number, and still ranged', () {
      final fine = RowValidator.validate(Tables.observations, {
        'observation_id': 'obs-1',
        'project_id': 'proj-1',
        'latitude': '42.5',
      });
      expect(fine, isEmpty, reason: '"42.5" is a latitude, quoted');

      final tooBig = RowValidator.validate(Tables.observations, {
        'observation_id': 'obs-1',
        'project_id': 'proj-1',
        'latitude': '999',
      });
      expect(tooBig.single.code, RowIssueCode.numberAboveMaximum);
    });

    test('the code is read off the limit, never typed at the refusal site',
        () {
      // The bound this task must not disturb: `RowIssueCode` values reach a
      // row through `NumericLimit.violationCode`. `wrongType` is the one limit
      // `violatedBy` cannot answer with, because it is decided before there is
      // a number to compare — so it is declared beside the others rather than
      // written into the validator.
      expect(NumericLimit.wrongType.violationCode, RowIssueCode.numberWrongType);
      expect(
        NumericLimit.values.map((l) => l.violationCode).toSet(),
        hasLength(NumericLimit.values.length),
        reason: 'two limits sharing a code makes one of them unsayable',
      );
    });
  });

  group('the two columns that claimed no honest range', () {
    // Task 11.158's second half. `unbounded` is a claim that nobody can name a
    // range, and for these two that claim was false in one direction.
    test('a revision cannot be negative', () {
      // What a negative revision does: `MergeResolver` treats a missing or
      // non-integer revision as 0, so a row arriving at -1 loses to every
      // copy of itself anywhere — including the edits its own holder makes
      // afterwards, which increment from -1 and stay behind. The person's
      // correction is silently discarded on the next sync. Zero is kept
      // because the app's own DDL defaults to it.
      final revision = syncColumns.firstWhere((c) => c.name == 'revision');
      expect(revision.numericBound!.violatedBy(-1), NumericLimit.belowMinimum);
      expect(revision.numericBound!.violatedBy(0), isNull);
      expect(revision.numericBound!.violatedBy(1e15), isNull,
          reason: 'no ceiling: a long-lived row keeps counting');

      final issues = RowValidator.validate(Tables.observations, {
        'observation_id': 'obs-1',
        'project_id': 'proj-1',
        'revision': -1,
      });
      expect(issues.single.field, 'revision');
      expect(issues.single.code, RowIssueCode.numberBelowMinimum);
    });

    test('a triangulation window cannot be zero or negative minutes', () {
      // The only writer is the project-settings field, which clamps to
      // 1..240. A window of zero minutes groups no observations at all, so
      // the floor is honest; no ceiling is declared, because 240 is one
      // screen's choice rather than a fact about the data.
      final issues = RowValidator.validate(Tables.projects, {
        'project_id': 'proj-1',
        'triangulation_window_minutes': 0,
      });
      expect(issues.single.field, 'triangulation_window_minutes');
      expect(issues.single.code, RowIssueCode.numberBelowMinimum);

      expect(
        RowValidator.validate(Tables.projects, {
          'project_id': 'proj-1',
          'triangulation_window_minutes': 1,
        }),
        isEmpty,
      );
    });
  });
}

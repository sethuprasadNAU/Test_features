import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **Task 11.28: the departure predicate on its own, with no database in the
/// way.**
///
/// [isSelfDeparture] is the single definition of "this write is one person
/// ending their own membership stint" that the app's repository and the
/// server's `RowAuthorizer` both apply, so it is the one place a disagreement
/// between them could hide. Both sides have their own end-to-end tests
/// (`test/data/repositories/leave_project_test.dart`,
/// `server/test/authz/leave_project_test.dart`); this file exercises the
/// decision itself, including the cases neither side can easily construct.
///
/// It lives in the app suite rather than the server's because the server's
/// runs only where Postgres does, and this needs no database at all — a
/// predicate whose tests are conditional is a predicate nobody knows is
/// working.
void main() {
  const caller = 'user-caller';
  const other = 'user-other';
  const at = '2026-08-01T12:00:00.000Z';
  const later = '2026-08-22T09:00:00.000Z';

  Map<String, Object?> stored({
    String userId = caller,
    String role = 'contributor',
    String? endDate,
    String? deletedAt,
  }) => {
    'membership_id': 'mem-1',
    'project_id': 'proj-1',
    'user_id': userId,
    'join_date': at,
    'end_date': endDate,
    'role': role,
    'created_at': at,
    'updated_at': at,
    'deleted_at': deletedAt,
    'revision': 0,
    'last_modified_by': userId,
    'origin_device_id': 'device-1',
  };

  /// The stored row with [changes] applied — the shape of a real push, where
  /// every column is present and one has moved.
  Map<String, Object?> incoming(
    Map<String, Object?> from, [
    Map<String, Object?> changes = const {},
  ]) => {
    ...from,
    'end_date': later,
    'updated_at': later,
    'revision': (from['revision'] as int) + 1,
    'last_modified_by': caller,
    ...changes,
  };

  bool departure(
    Map<String, Object?>? existing,
    Map<String, Object?> proposed, {
    String? by = caller,
    String table = Tables.projectMemberships,
  }) => isSelfDeparture(
    table: table,
    callerUserId: by,
    existing: existing,
    incoming: proposed,
  );

  group('what a departure is', () {
    test('setting your own open stint\'s end date', () {
      final row = stored();
      expect(departure(row, incoming(row)), isTrue);
    });

    test('the sync bookkeeping columns are free to move', () {
      final row = stored();
      expect(
        departure(
          row,
          incoming(row, {'origin_device_id': 'a-different-phone'}),
        ),
        isTrue,
        reason: 'leaving from your other device is still leaving',
      );
    });

    test('a viewer\'s row is no different from anybody else\'s', () {
      // The predicate says nothing about role, deliberately: the role gradient
      // is applied by the caller, and this is the thing that overrides it.
      final row = stored(role: 'viewer');
      expect(departure(row, incoming(row)), isTrue);
    });

    test('an owner\'s row is no different either', () {
      // Whether the *last* owner may leave is a separate rule, enforced by the
      // last-owner guard on both sides. This predicate must not quietly answer
      // it, or there would be two half-answers instead of one whole one.
      final row = stored(role: 'owner');
      expect(departure(row, incoming(row)), isTrue);
    });
  });

  group('what a departure is not', () {
    test('somebody else\'s row, even ended honestly', () {
      final row = stored(userId: other);
      expect(departure(row, incoming(row)), isFalse);
    });

    test('somebody else\'s row relabelled as yours', () {
      // The takeover shape. The subject is read from the **stored** row, so
      // the claim in the incoming copy cannot change the answer — and the
      // immutable-column rule refuses the relabelling independently.
      final row = stored(userId: other);
      expect(departure(row, incoming(row, {'user_id': caller})), isFalse);
    });

    test('an insert', () {
      expect(departure(null, incoming(stored())), isFalse);
    });

    test('a stint that is already over', () {
      final row = stored(endDate: '2026-07-01T00:00:00.000Z');
      expect(departure(row, incoming(row)), isFalse);
    });

    test('a stint that is already tombstoned', () {
      final row = stored(deletedAt: '2026-07-01T00:00:00.000Z');
      expect(departure(row, incoming(row)), isFalse);
    });

    test('a write that leaves the end date null', () {
      final row = stored();
      expect(departure(row, incoming(row, {'end_date': null})), isFalse);
    });

    test('a write that sets an empty end date', () {
      final row = stored();
      expect(departure(row, incoming(row, {'end_date': ''})), isFalse);
    });

    test('a write whose end date is not a string', () {
      // Fails closed rather than being tolerated: every timestamp column is
      // text on both sides, so a non-string is either a bug or a probe, and
      // neither should reach the permitting branch.
      final row = stored();
      expect(departure(row, incoming(row, {'end_date': 1})), isFalse);
    });

    test('leaving and promoting yourself in the same write', () {
      final row = stored();
      expect(departure(row, incoming(row, {'role': 'owner'})), isFalse);
    });

    test('leaving and demoting yourself in the same write', () {
      // Refused in both directions. The point is not that `owner` is
      // dangerous, it is that a closed stint's role is the historical record
      // of what somebody was, and a departure must not restate it.
      final row = stored();
      expect(departure(row, incoming(row, {'role': 'viewer'})), isFalse);
    });

    test('leaving and tombstoning in the same write', () {
      expect(
        departure(stored(), incoming(stored(), {'deleted_at': later})),
        isFalse,
      );
    });

    test('leaving and re-dating the stint', () {
      expect(
        departure(stored(), incoming(stored(), {'join_date': '2020-01-01'})),
        isFalse,
      );
    });

    test('leaving and rewriting created_at', () {
      expect(
        departure(stored(), incoming(stored(), {'created_at': '2020-01-01'})),
        isFalse,
      );
    });

    test('leaving and moving the row to another project', () {
      expect(
        departure(stored(), incoming(stored(), {'project_id': 'proj-2'})),
        isFalse,
      );
    });

    test('leaving and renumbering the row', () {
      expect(
        departure(stored(), incoming(stored(), {'membership_id': 'mem-2'})),
        isFalse,
      );
    });

    test('an anonymous caller', () {
      expect(departure(stored(), incoming(stored()), by: null), isFalse);
      expect(departure(stored(), incoming(stored()), by: ''), isFalse);
    });

    test('any other table', () {
      // The predicate is applied at one call site on the server and one in the
      // app, both of which already know the table. Checking it here as well is
      // what makes it safe to move either call site.
      for (final table in Tables.all) {
        if (table == Tables.projectMemberships) continue;
        expect(
          departure(stored(), incoming(stored()), table: table),
          isFalse,
          reason: '$table is not Project_Memberships',
        );
      }
    });
  });

  group('the mutable set is declared against the schema', () {
    test('every declared mutable column exists', () {
      assertDepartureColumnsExist();
    });

    test('the guard fires on a column that does not exist', () {
      expect(
        () => assertDepartureColumnsExist(
          mutableColumns: const {'end_date', 'not_a_column'},
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('the two sets partition the table, with nothing left over', () {
      // The property that makes this maintainable: a column added to
      // `Project_Memberships` in a future migration is immutable during a
      // departure without anybody remembering to say so, and the day somebody
      // needs it to move they have to come and declare it.
      final declared = tableSpecsByName[Tables.projectMemberships]!.columnNames
          .toSet();
      expect(
        departureMutableColumns.union(departureImmutableColumns),
        declared,
      );
      expect(
        departureMutableColumns.intersection(departureImmutableColumns),
        isEmpty,
      );
      for (final column in const [
        'membership_id',
        'project_id',
        'user_id',
        'join_date',
        'role',
        'created_at',
        'deleted_at',
      ]) {
        expect(departureImmutableColumns, contains(column));
      }
    });
  });
}

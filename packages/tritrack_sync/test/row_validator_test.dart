import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

void main() {
  group('RowValidator', () {
    test('its private primary-key map still matches syncTables', () {
      // `RowValidator._pkValue` hand-copies the primary keys rather than
      // importing `syncTables`, to keep the validator dependency-light. That is
      // a defensible trade and also exactly the two-places-must-agree hazard
      // that task 10.35 had to fix in several spots at once — so it is pinned
      // rather than trusted.
      //
      // Checked through the public surface: a row missing a required field
      // reports its primary key, so a divergent map shows up as a wrong
      // `primaryKeyValue`. Every table is exercised, because the failure mode
      // is one table being forgotten, not all of them.
      for (final table in syncTables) {
        final row = {
          for (var i = 0; i < table.primaryKey.length; i++)
            table.primaryKey[i]: 'k$i',
        };
        final issues = RowValidator.validate(table.name, {
          ...row,
          // A value no enum or range accepts, so at least one issue is raised
          // on every table regardless of which columns it has.
          'position_source': 'not-a-real-source',
          'status': 'not-a-real-status',
          'role': 'not-a-real-role',
        });
        if (issues.isEmpty) continue;
        expect(
          issues.first.primaryKeyValue,
          [for (var i = 0; i < table.primaryKey.length; i++) 'k$i'].join('/'),
          reason:
              '${table.name}: RowValidator disagrees with syncTables '
              'about the primary key',
        );
      }
    });

    test('a well-formed observation row has no issues', () {
      final issues = RowValidator.validate(Tables.observations, {
        'latitude': 34.0,
        'longitude': -111.0,
        'position_accuracy_m': 5.0,
        'magnetic_bearing': 90.0,
        'true_north_bearing': 95.0,
        'bearing_uncertainty': 2.0,
        'position_source': 'gps_fix',
        'observation_type': 'directional',
        'bearing_capture_method': 'single_point',
        'bearing_method': 'peak',
        'signal_type': 'regular_pulse',
        'signal_strength': 'strong',
        'bearing_quality': 'good',
      });
      expect(issues, isEmpty);
    });

    test('null optional fields are not flagged', () {
      final issues = RowValidator.validate(Tables.observations, {
        'latitude': 34.0,
        'longitude': -111.0,
        'position_source': 'gps_fix',
        'observation_type': 'note',
      });
      expect(issues, isEmpty);
    });

    test('out-of-range bearing is rejected', () {
      final issues = RowValidator.validate(Tables.observations, {
        'latitude': 34.0,
        'longitude': -111.0,
        'position_source': 'gps_fix',
        'observation_type': 'directional',
        'magnetic_bearing': 361.0,
      });
      expect(issues, hasLength(1));
      expect(issues.single.field, 'magnetic_bearing');
    });

    test('an unrecognized enum value is rejected', () {
      final issues = RowValidator.validate(Tables.observations, {
        'latitude': 34.0,
        'longitude': -111.0,
        'position_source': 'teleported',
        'observation_type': 'directional',
      });
      expect(issues, hasLength(1));
      expect(issues.single.field, 'position_source');
    });

    test('out-of-range latitude/longitude are rejected', () {
      final issues = RowValidator.validate(Tables.actualTagLocations, {
        'latitude': 91.0,
        'longitude': -200.0,
        'uncertainty_radius': 10.0,
      });
      expect(
        issues.map((i) => i.field),
        containsAll(['latitude', 'longitude']),
      );
    });

    test('a non-positive uncertainty is rejected', () {
      final issues = RowValidator.validate(Tables.actualTagLocations, {
        'latitude': 34.0,
        'longitude': -111.0,
        'uncertainty_radius': 0.0,
      });
      expect(issues, hasLength(1));
      expect(issues.single.field, 'uncertainty_radius');
    });

    test('a malformed tag color is rejected', () {
      final issues = RowValidator.validate(Tables.tags, {
        'frequency_mhz': 150.0,
        'status': 'active',
        'color_hex': 'not-a-color',
      });
      expect(issues, hasLength(1));
      expect(issues.single.field, 'color_hex');
    });

    test('an empty email is rejected', () {
      final issues = RowValidator.validate(Tables.users, {'email': '   '});
      expect(issues, hasLength(1));
      expect(issues.single.field, 'email');
    });

    test('composite primary keys are joined for display', () {
      // `Tags` is the composite this used to reach for `Project_Tags` for —
      // it became `(tag_id, project_id)` in task 11.219, and the key is
      // written id-first for the reason `syncTables` gives.
      final issues = RowValidator.validate(Tables.tags, {
        'tag_id': 'tag-1',
        'project_id': 'proj-1',
        'status': 'not-a-real-status',
      });
      expect(issues.single.primaryKeyValue, 'tag-1/proj-1');
    });

    // Task 10.56, finding I-5's class generalized: any primary-key column is a
    // Postgres btree index entry, so an oversized value does not draw a typed
    // refusal at insert time — it throws. Refused here instead, before it
    // ever reaches a query.
    test('an oversized primary-key column is rejected', () {
      final issues = RowValidator.validate(Tables.tags, {
        'tag_id': 'x' * (RowValidator.maxPrimaryKeyLength + 1),
        'status': 'active',
      });
      expect(issues, hasLength(1));
      expect(issues.single.field, 'tag_id');
    });

    test('a primary-key column at the bound is accepted', () {
      final issues = RowValidator.validate(Tables.tags, {
        'tag_id': 'x' * RowValidator.maxPrimaryKeyLength,
        'status': 'active',
      });
      expect(issues, isEmpty);
    });

    test(
      'every composite primary-key column is checked, not just the first',
      () {
        final issues = RowValidator.validate(Tables.tags, {
          'tag_id': 'tag-1',
          'project_id': 'x' * (RowValidator.maxPrimaryKeyLength + 1),
        });
        expect(issues, hasLength(1));
        expect(issues.single.field, 'project_id');
      },
    );

    // Same class again: `Users.email`/`User_Emails.email` are btree-indexed
    // for cross-device dedup, not primary keys, and had no length bound at
    // all before task 10.56.
    test('an oversized email is rejected', () {
      final overlong = '${'x' * (RowValidator.maxEmailLength - 4)}@a.co';
      expect(overlong.length, RowValidator.maxEmailLength + 1);
      final issues = RowValidator.validate(Tables.users, {'email': overlong});
      expect(issues, hasLength(1));
      expect(issues.single.field, 'email');
    });

    test('an email at the bound is accepted', () {
      final atBound = '${'x' * (RowValidator.maxEmailLength - 5)}@a.co';
      expect(atBound.length, RowValidator.maxEmailLength);
      final issues = RowValidator.validate(Tables.users, {'email': atBound});
      expect(issues, isEmpty);
    });

    // Task 10.67: a present-but-wrong-typed primary-key column matched
    // neither `value is String` branch of the old length check and fell
    // through with NO issue recorded — silently treated the same as a
    // validly-shaped key, rather than being refused before it reached a
    // model's `as String` cast or the database insert itself.
    group('wrong-typed primary key (task 10.67)', () {
      test('a non-string primary key is rejected, not silently accepted', () {
        final issues = RowValidator.validate(Tables.tags, {
          'tag_id': 12345,
          'status': 'active',
        });
        expect(issues, hasLength(1));
        expect(issues.single.field, 'tag_id');
      });

      test('a boolean primary key is rejected', () {
        final issues = RowValidator.validate(Tables.tags, {
          'tag_id': true,
          'status': 'active',
        });
        expect(issues, hasLength(1));
        expect(issues.single.field, 'tag_id');
      });

      test('a nested-map primary key is rejected', () {
        final issues = RowValidator.validate(Tables.tags, {
          'tag_id': 'tag-1',
          'project_id': {'nested': true},
        });
        expect(issues, hasLength(1));
        expect(issues.single.field, 'project_id');
      });

      test('a null primary key is still not flagged here (NOT NULL is left '
          'to the database)', () {
        final issues = RowValidator.validate(Tables.tags, {
          'tag_id': null,
          'status': 'active',
        });
        expect(issues, isEmpty);
      });
    });

    // Task 10.67: identity/authorship columns (`user_id`, `owner_user_id`,
    // and the `SyncMeta` audit columns every synced table carries) had no
    // type check at all — the client-side sibling of the class task 10.64
    // fixed in `RowAuthorizer._governingValue` server-side. A malformed
    // value here would previously reach `base_repository.dart`'s advisory
    // authorization check (or a model's `fromRow`) unguarded instead of
    // being refused at the one gate every write path (including the merge
    // path) runs through.
    group('wrong-typed identity columns (task 10.67)', () {
      test('a non-string owner_user_id on Projects is rejected', () {
        final issues = RowValidator.validate(Tables.projects, {
          'project_id': 'proj-1',
          'owner_user_id': 12345,
        });
        expect(issues, hasLength(1));
        expect(issues.single.field, 'owner_user_id');
      });

      test('a null owner_user_id is not flagged (NOT NULL is left to the '
          'database)', () {
        final issues = RowValidator.validate(Tables.projects, {
          'project_id': 'proj-1',
          'owner_user_id': null,
        });
        expect(issues, isEmpty);
      });

      test('a non-string user_id on Observations (the author column) is '
          'rejected', () {
        final issues = RowValidator.validate(Tables.observations, {
          'observation_id': 'obs-1',
          'project_id': 'proj-1',
          'user_id': 999,
          'latitude': 34.0,
          'longitude': -111.0,
        });
        expect(issues, hasLength(1));
        expect(issues.single.field, 'user_id');
      });

      test('a non-string user_id on Non_Detections is rejected', () {
        final issues = RowValidator.validate(Tables.nonDetections, {
          'non_detection_id': 'nd-1',
          'project_id': 'proj-1',
          'user_id': false,
          'latitude': 34.0,
          'longitude': -111.0,
        });
        expect(issues, hasLength(1));
        expect(issues.single.field, 'user_id');
      });

      test('a non-string user_id on Project_Memberships is rejected', () {
        final issues = RowValidator.validate(Tables.projectMemberships, {
          'membership_id': 'mem-1',
          'project_id': 'proj-1',
          'user_id': 42,
        });
        expect(issues, hasLength(1));
        expect(issues.single.field, 'user_id');
      });

      test('a non-string last_modified_by is rejected on any table', () {
        final issues = RowValidator.validate(Tables.tags, {
          'tag_id': 'tag-1',
          'status': 'active',
          'last_modified_by': 12345,
        });
        expect(issues, hasLength(1));
        expect(issues.single.field, 'last_modified_by');
      });

      test('a non-string origin_device_id is rejected on any table', () {
        final issues = RowValidator.validate(Tables.tags, {
          'tag_id': 'tag-1',
          'status': 'active',
          'origin_device_id': 12345,
        });
        expect(issues, hasLength(1));
        expect(issues.single.field, 'origin_device_id');
      });

      test('a null last_modified_by/origin_device_id is not flagged — a '
          'legitimately-merged row may not have synced its author yet', () {
        final issues = RowValidator.validate(Tables.tags, {
          'tag_id': 'tag-1',
          'status': 'active',
          'last_modified_by': null,
          'origin_device_id': null,
        });
        expect(issues, isEmpty);
      });
    });

    // Task 11.22. Tasks 10.64 and 10.68's own write-ups enumerated which
    // governing columns `RowValidator` shadows — hand-maintained lists, and
    // both turned out to miss `Observation_Exclusions` (task 11.17). This
    // derives the list from the code instead of carrying one: it reads
    // straight from `tableMutationRules`/`MutationRule.governingColumn`, so a
    // table added there without a matching `RowValidator` check fails here
    // rather than silently joining an accurate-looking list. That gap matters
    // because of what task 10.64 found the hard way — an unchecked governing
    // column crashed a whole push, and the tempting fix (default the bad
    // value to null) would have turned the crash into an authorization
    // *bypass*, since `MutationRule.permits` reads a null governing value as
    // permitted.
    test(
      'every table whose MutationRule has a governing column has that '
      'column type-checked by RowValidator',
      () {
        for (final entry in tableMutationRules.entries) {
          final table = entry.key;
          final governingColumn = entry.value.governingColumn;
          if (governingColumn == null) {
            continue; // anyUser: nothing singles a caller out on the row.
          }
          final issues = RowValidator.validate(table, {governingColumn: 12345});
          expect(
            issues.map((issue) => issue.field),
            contains(governingColumn),
            reason:
                '$table: RowValidator does not type-check its governing '
                'column ($governingColumn, MutationRule.${entry.value.name}). '
                'A malformed value here reaches authorization unshadowed — '
                'see task 10.64.',
          );
        }
      },
    );
  });

  group('NaN and the infinities (finding M-1)', () {
    // NaN is *unordered*, not out of range: `NaN < min` and `NaN > max` are
    // both false, so it passed every bound this validator had. Stored as a
    // coordinate it is never plotted, never filtered out, never flagged, and
    // poisons any mean or bounding box computed over the dataset.
    for (final bad in <Object>[double.nan, 'NaN', double.infinity,
        double.negativeInfinity, '-Infinity']) {
      test('a $bad latitude is refused', () {
        final issues = RowValidator.validate(Tables.observations, {
          'observation_id': 'obs-1',
          'latitude': bad,
        });
        expect(issues.map((i) => i.field), contains('latitude'));
      });
    }

    test('NaN is refused by a positive-only check too', () {
      // `NaN <= 0` is also false, so these were open as well.
      final issues = RowValidator.validate(Tables.observations, {
        'observation_id': 'obs-1',
        'bearing_uncertainty': double.nan,
      });
      expect(issues.map((i) => i.field), contains('bearing_uncertainty'));
    });

    test('NaN is refused on a column with no range at all', () {
      // `altitude_agl` and `elevation` have no min or max anybody can defend,
      // so nothing checked them — which made them the widest door NaN had.
      final issues = RowValidator.validate(Tables.observations, {
        'observation_id': 'obs-1',
        'altitude_agl': double.nan,
        'elevation': double.infinity,
      });
      expect(
        issues.map((i) => i.field),
        containsAll(<String>['altitude_agl', 'elevation']),
      );
    });

    test('an ordinary number still passes', () {
      final issues = RowValidator.validate(Tables.observations, {
        'observation_id': 'obs-1',
        'latitude': 35.19,
        'longitude': -111.65,
        'elevation': 2100.0,
        'altitude_agl': 0.0,
      });
      expect(issues, isEmpty);
    });
  });

  group('text length bounds (findings L-7 and N-7)', () {
    test('a 5 MiB tag name is refused', () {
      // Measured live before this bound existed: stored, synced, and delivered
      // to every device on the project.
      final issues = RowValidator.validate(Tables.tags, {
        'tag_id': 'tag-1',
        'tag_name': 'x' * (5 * 1024 * 1024),
      });
      expect(issues.map((i) => i.field), contains('tag_name'));
    });

    test('the three Observation_Exclusions columns are bounded', () {
      // The table that proved a hand-written list cannot notice a new column:
      // it arrived after L-7's list was written, with three unbounded columns.
      final issues = RowValidator.validate(Tables.observationExclusions, {
        'exclusion_id': 'exc-1',
        'reason': 'x' * 100000,
        'superseded_by_observation_id': 'y' * 100000,
      });
      expect(
        issues.map((i) => i.field),
        containsAll(<String>['reason', 'superseded_by_observation_id']),
      );
    });

    test('an identifier-shaped column wants a shape, not just a length', () {
      // A control character inside an id is short enough to pass any length
      // cap, and forges a line break in anything line-oriented that renders it.
      final issues = RowValidator.validate(Tables.observationExclusions, {
        'exclusion_id': 'exc-1',
        'observation_id': 'a\u0000b',
      });
      expect(issues.map((i) => i.field), contains('observation_id'));
    });

    test('an ordinary tag name and note still pass', () {
      final issues = RowValidator.validate(Tables.tags, {
        'tag_id': 'tag-1',
        'tag_name': 'Collar 148.520',
        'notes': 'Refitted after the January recapture.',
      });
      expect(issues, isEmpty);
    });
  });

  test('the two places that bound an identifier agree on the number', () {
    // They live in different files. A silent disagreement would mean a value
    // refused by one gate and accepted by the other.
    expect(TextBound.identifier.maxLength, RowValidator.maxPrimaryKeyLength);
    expect(TextBound.email.maxLength, RowValidator.maxEmailLength);
  });
}

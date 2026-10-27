import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.32's forcing function: **adding a column to `Tags` must be a
/// decision somebody wrote down, not a default.**
///
/// The judgement — is this a display key, measurement context, or a fact about
/// the collar's life — cannot be automated. Omitting it can be made
/// impossible, and that is what these tests hold.
void main() {
  group('every tag column declares its kind', () {
    test('the real schema passes', () {
      expect(assertEveryTagColumnDeclaresItsKind, returnsNormally);
    });

    // **Proving the guard can fail.** A guard nobody has seen fail is not a
    // guard — eight consecutive security gates on this project found that shape
    // in its own instruments. This is the acceptance criterion "adding a column
    // to the tag table with no declared kind fails a test, demonstrated by
    // adding one", done by handing the assertion a doctored column list rather
    // than by editing the schema and putting it back.
    test('a new tag column with no declared kind fails', () {
      final doctored = [
        ...tableSpecsByName[Tables.tags]!.columns,
        const ColumnSpec('battery_months_remaining', ColumnType.real),
      ];
      expect(
        () => assertEveryTagColumnDeclaresItsKind(tagColumns: doctored),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('battery_months_remaining'),
              contains('no default'),
            ),
          ),
        ),
      );
    });

    test('a declared column the schema no longer has fails too', () {
      final doctored = [
        for (final column in tableSpecsByName[Tables.tags]!.columns)
          if (column.name != 'pulse_pattern') column,
      ];
      expect(
        () => assertEveryTagColumnDeclaresItsKind(tagColumns: doctored),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('pulse_pattern'),
          ),
        ),
      );
    });
  });

  group('the classification itself', () {
    test('colour is never versioned, and since v16 it is not a tag column at all',
        () {
      // The correction that made this design right (task 11.32): freezing
      // colour would redraw last season's bearings in the old colour when
      // somebody recolours, which is nobody's intent — a colour is a display
      // key a person chose, not a measurement taken in the field.
      //
      // Task 11.240 moved colour's home to `Individuals.color_hex`, and the
      // reason that was cheap is the same fact: a live-read value changes
      // where it comes from and nothing about how it behaves. The tag's own
      // column is retired — kept on the wire, written null, read by nothing.
      expect(tagColumnKinds['color_hex'], TagColumnKind.retired);
      expect(versionedTagColumnNames, isNot(contains('color_hex')));
      expect(
        tableSpecsByName[Tables.tags]!.columns
            .firstWhere((c) => c.name == 'color_hex')
            .nullable,
        isTrue,
        reason: 'a v16 writer sends null; the column must accept it',
      );
      expect(
        tableSpecsByName[Tables.individuals]!.columns
            .firstWhere((c) => c.name == 'color_hex')
            .nullable,
        isFalse,
        reason: 'the one home of colour cannot be empty',
      );
    });

    test('a tag no longer says anything about an animal or a date', () {
      // **Task 11.243 deleted the four columns this test used to be about.**
      // It asserted `individual_id` was `collarLife` *and* that the
      // redeployment rule making that safe was in the comment directly above
      // the entry. The rule was withdrawn (design §2) and the column with it:
      // the link is a dated `Deployments` row now.
      //
      // What replaces it is the same question asked of the table as a whole —
      // does a tag claim to know who wore it, or when? A column named here
      // would also be a column `assertEveryTagColumnDeclaresItsKind` demands
      // exist, so this fails on the map and the spec together.
      for (final gone in [
        'individual_id',
        'date_put_on',
        'date_removed',
        'capture_date',
      ]) {
        expect(
          tagColumnKinds.containsKey(gone),
          isFalse,
          reason:
              '$gone left Tags at schema v17 — a tag is equipment, and the '
              'dated link is Deployments',
        );
        expect(
          tableSpecsByName[Tables.tags]!.columnNames,
          isNot(contains(gone)),
          reason: '$gone must be gone from the spec as well as the map',
        );
      }
    });

    test('the measurement context is exactly the fields a bearing depends on',
        () {
      // Four until task 11.187, which added the tag's pulse modes: a bearing
      // was heard on a mode with a name and a rate, and renaming that mode
      // afterwards must not rewrite what the bearing says it was heard on.
      // Slot 1's rate is `pulse_rate`, already here — see `pulse_modes.dart`
      // for why that column could not be renamed.
      expect(versionedTagColumnNames, {
        'frequency_mhz',
        'pulse_rate',
        'pulse_pattern',
        'tag_name',
        'pulse_mode_1_name',
        'pulse_mode_2_name',
        'pulse_mode_2_rate_bpm',
        'pulse_mode_3_name',
        'pulse_mode_3_rate_bpm',
      });
    });

    test("the collar's own life is current-state-only", () {
      // Five until task 11.243 moved three dates onto `Deployments`. What is
      // left is what genuinely describes the transmitter rather than one
      // deployment of it.
      for (final column in ['status', 'notes']) {
        expect(tagColumnKinds[column], TagColumnKind.collarLife, reason: column);
      }
    });

    test('the sync columns are classified rather than exempted', () {
      // An exemption is where this project keeps finding its next problem.
      for (final column in syncColumns) {
        expect(
          tagColumnKinds[column.name],
          TagColumnKind.bookkeeping,
          reason: '${column.name} must be listed, not skipped',
        );
      }
    });
  });

  group('Tag_Versions is derived from the classification, not written out', () {
    final spec = tableSpecsByName[Tables.tagVersions]!;

    test('it carries exactly the versioned tag columns, and no others', () {
      final own = spec.columnNames.toSet()
        // Its own key and parentage: the version's id, the tag it versions,
        // the project both live in (task 11.219), and when it took effect.
        ..removeAll([
          'tag_version_id',
          'project_id',
          'tag_id',
          'effective_from',
        ])
        ..removeAll(syncColumns.map((c) => c.name));
      expect(own, versionedTagColumnNames);
    });

    test('it carries no provenance column', () {
      // Task 11.219. A version records what the collar read; where this copy
      // of the tag came from is not a measurement, and a version row that
      // carried a lineage would put it on the wire once per bearing.
      for (final column in provenanceColumns[Tables.tags]!) {
        expect(tagColumnKinds[column], TagColumnKind.provenance);
        expect(spec.columnNames, isNot(contains(column)), reason: column);
      }
    });

    test('each carried column keeps the type and nullability Tags gives it',
        () {
      final tags = tableSpecsByName[Tables.tags]!;
      for (final name in versionedTagColumnNames) {
        final onTag = tags.columns.firstWhere((c) => c.name == name);
        final onVersion = spec.columns.firstWhere((c) => c.name == name);
        expect(onVersion.type, onTag.type, reason: '$name type');
        expect(
          spec.isNotNull(onVersion),
          tags.isNotNull(onTag),
          reason: '$name nullability — a value the tag table refuses must not '
              'become storable by arriving as a version of that tag',
        );
      }
    });

    test('it carries no display or collar-life column', () {
      for (final entry in tagColumnKinds.entries) {
        if (entry.value == TagColumnKind.display ||
            entry.value == TagColumnKind.collarLife) {
          // `project_id` is identity, not either of these, so the exclusion
          // above does not accidentally cover it.
          expect(entry.key, isNot('project_id'));
          expect(
            spec.columnNames,
            isNot(contains(entry.key)),
            reason: '${entry.key} is ${entry.value.name} — freezing it into a '
                'record would be as wrong as letting frequency float',
          );
        }
      }
    });
  });

  group('the validator bounds every versioned tag column, or says it did not',
      () {
    // Task 11.32's own instance of the governing-column discipline: the schema
    // supplies the list of columns owing a judgement, so a new
    // `measurementContext` column with no bound and no decision is a red test
    // rather than an unchecked value on a synced table.
    /// **Task 11.136 replaced the two hand-kept sets this used to read.**
    /// `RowValidator` carried `rangeCheckedVersionedTagColumns` and
    /// `unboundedFreeTextVersionedTagColumns` — a list of which versioned tag
    /// columns had been thought about — because the bounds themselves were
    /// written inline and there was nothing else to ask. Now every column
    /// declares its own bound, so the question is asked of the schema, and
    /// there is no second list to fall behind it.
    test('every versioned column declares what bounds it', () {
      final spec = tableSpecs.firstWhere(
        (s) => s.name == Tables.tagVersions,
      );
      for (final name in versionedTagColumnNames) {
        final column = spec.columns.firstWhere((c) => c.name == name);
        expect(
          column.type == ColumnType.text
              ? column.bound
              : column.numericBound,
          isNotNull,
          reason: '$name is versioned and nobody has said what bounds it — '
              'pick a TextBound/NumericBound, or say NumericBound.unbounded '
              'to record that somebody looked and judged it unbounded',
        );
      }
    });

    test('the same bound applies to Tags and to Tag_Versions', () {
      // A frequency the tag table refuses must not become storable by arriving
      // as a version of that tag. **Structural since task 11.136:**
      // `Tag_Versions` is derived from the same `ColumnSpec` list, so the two
      // carry the identical bound object rather than two calls to one helper.
      final tags = tableSpecs.firstWhere((s) => s.name == Tables.tags);
      final versions = tableSpecs.firstWhere(
        (s) => s.name == Tables.tagVersions,
      );
      for (final name in versionedTagColumnNames) {
        expect(
          versions.columns.firstWhere((c) => c.name == name).numericBound,
          same(tags.columns.firstWhere((c) => c.name == name).numericBound),
          reason: '$name must carry one bound, not two that can disagree',
        );
      }
      for (final table in [Tables.tags, Tables.tagVersions]) {
        expect(
          RowValidator.validate(table, {'frequency_mhz': 99999.0}),
          isNotEmpty,
          reason: '$table accepted an out-of-band frequency',
        );
        expect(
          RowValidator.validate(table, {'pulse_rate': -1.0}),
          isNotEmpty,
          reason: '$table accepted a negative pulse rate',
        );
      }
    });

    test('Tag_Versions type-checks the tag it names', () {
      // `tag_id` is not this table's primary key, so the primary-key loop does
      // not reach it — the same gap task 11.22 found on `User_Emails.user_id`.
      final issues = RowValidator.validate(Tables.tagVersions, {
        'tag_version_id': 'v-1',
        'tag_id': 12345,
      });
      expect(issues.map((i) => i.field), contains('tag_id'));
    });

    test('a well-formed version row is accepted', () {
      expect(
        RowValidator.validate(Tables.tagVersions, {
          'tag_version_id': 'v-1',
          'tag_id': 'tag-1',
          'effective_from': '2026-08-22T00:00:00.000Z',
          'frequency_mhz': 150.325,
          'pulse_rate': 40.0,
          'pulse_pattern': 'steady',
          'tag_name': 'Coco',
          'created_at': '2026-08-22T00:00:00.000Z',
          'updated_at': '2026-08-22T00:00:00.000Z',
          'revision': 0,
          'last_modified_by': 'user-1',
          'origin_device_id': 'device-A',
        }),
        isEmpty,
      );
    });
  });
}

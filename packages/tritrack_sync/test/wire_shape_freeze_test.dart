import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// `assertWireShapeCompatibleWithMajor` — task 11.242 — watched refusing every
/// row of its own table, and passing every row it says it allows.
///
/// The doctored declarations below are built by editing one column of a copy
/// of the live `tableSpecs`, then freezing *one* side and checking the other,
/// so each test is "the wire was like this when the major began, and now it
/// is like that". A check nobody has seen fail is a check nobody knows works.
void main() {
  /// A copy of the live specs with one column of one table replaced.
  List<TableSpec> withColumn(
    String table,
    String column,
    ColumnSpec Function(ColumnSpec) edit,
  ) => [
    for (final t in tableSpecs)
      t.name != table
          ? t
          : TableSpec(t.name, [
              for (final c in t.columns) c.name == column ? edit(c) : c,
            ]),
  ];

  /// A copy with one column of one table removed.
  List<TableSpec> without(String table, String column) => [
    for (final t in tableSpecs)
      t.name != table
          ? t
          : TableSpec(t.name, [
              for (final c in t.columns)
                if (c.name != column) c,
            ]),
  ];

  /// A copy with a column appended to one table.
  List<TableSpec> withAdded(String table, ColumnSpec added) => [
    for (final t in tableSpecs)
      t.name != table ? t : TableSpec(t.name, [...t.columns, added]),
  ];

  ColumnSpec respec(
    ColumnSpec c, {
    ColumnType? type,
    bool? nullable,
    bool? primaryKey,
    TextBound? bound,
    NumericBound? numericBound,
    bool dropBounds = false,
  }) => ColumnSpec(
    c.name,
    type ?? c.type,
    nullable: nullable ?? c.nullable,
    primaryKey: primaryKey ?? c.primaryKey,
    bound: dropBounds ? null : (bound ?? c.bound),
    numericBound: dropBounds ? null : (numericBound ?? c.numericBound),
  );

  /// Freezes [before] as major 99's shape and checks [after] against it.
  void check(List<TableSpec> before, List<TableSpec> after) =>
      assertWireShapeCompatibleWithMajor(
        specs: after,
        major: 99,
        freezes: {
          99: freezeWireShape(specs: before, major: 99, schemaVersion: 50),
        },
        firstMinors: const {99: 50},
      );

  Matcher refuses(String fragment) => throwsA(
    isA<StateError>().having((e) => e.message, 'message', contains(fragment)),
  );

  group('the live declaration', () {
    test('is compatible with the freeze for the current major', () {
      expect(assertWireShapeCompatibleWithMajor, returnsNormally);
    });

    test('has a freeze for the current major, taken at its first minor', () {
      final frozen = frozenWireShapes[schemaMajorVersion];
      expect(
        frozen,
        isNotNull,
        reason:
            'every major from 4 on is frozen when it begins — run '
            '`dart run tool/freeze_wire_shape.dart`',
      );
      expect(frozen!.schemaVersion, schemaMajorFirstMinor[schemaMajorVersion]);
      expect(
        frozen.tables.map((t) => t.name),
        containsAll(Tables.all),
        reason: 'every wire table is in the freeze',
      );
    });

    test('a freeze of the live shape is byte-for-byte the renderer\'s own '
        'output for the same input — the encoding round-trips', () {
      // Not "the file on disk equals this" — that would fail on the first
      // nullable column a minor adds, which is exactly the change the design
      // allows. Only that rendering is deterministic and covers every table.
      final once = renderFrozenWireShapes({4: freezeWireShape(major: 4)});
      final twice = renderFrozenWireShapes({4: freezeWireShape(major: 4)});
      expect(once, twice);
      for (final table in Tables.all) {
        expect(once, contains("FrozenTable('$table'"));
      }
    });
  });

  group('the case this exists because of', () {
    test('Tags.color_hex losing NOT NULL, exactly as task 11.240 did it', () {
      // The wire as every v15 build stored it: colour NOT NULL.
      final v15 = withColumn(
        Tables.tags,
        'color_hex',
        (c) => respec(c, nullable: false),
      );
      // The wire as v16 declares it today.
      expect(
        () => check(v15, tableSpecs),
        refuses(
          'Tags.color_hex was NOT NULL when major 99 began and is '
          'nullable now',
        ),
      );
      expect(() => check(v15, tableSpecs), refuses('task 11.240'));
    });
  });

  group('every incompatible change in the table is refused', () {
    test('a table gone from the wire', () {
      final after = tableSpecs.where((t) => t.name != Tables.nonDetections);
      expect(
        () => check(tableSpecs, after.toList()),
        refuses('Non_Detections was on the wire when major 99 began'),
      );
    });

    test('a column gone (delete or rename — the same from here)', () {
      expect(
        () => check(tableSpecs, without(Tables.tags, 'notes')),
        refuses('Tags.notes was on the wire when major 99 began'),
      );
    });

    test('a column retyped', () {
      final after = withColumn(
        Tables.tags,
        'pulse_rate',
        (c) => respec(c, type: ColumnType.integer),
      );
      expect(
        () => check(tableSpecs, after),
        refuses('Tags.pulse_rate was real when major 99 began and is integer'),
      );
    });

    test('nullable becoming NOT NULL — a tightened rule', () {
      final after = withColumn(
        Tables.tags,
        'notes',
        (c) => respec(c, nullable: false),
      );
      expect(
        () => check(tableSpecs, after),
        refuses('Tags.notes was nullable when major 99 began and is NOT NULL'),
      );
    });

    test('a column joining the primary key', () {
      final after = withColumn(
        Tables.tags,
        'lineage_id',
        (c) => respec(c, primaryKey: true),
      );
      expect(
        () => check(tableSpecs, after),
        refuses('Tags.lineage_id was not part of the primary key'),
      );
    });

    test('a column leaving the primary key', () {
      final after = withColumn(
        Tables.tags,
        'project_id',
        (c) => respec(c, primaryKey: false),
      );
      expect(
        () => check(tableSpecs, after),
        refuses('Tags.project_id was part of the primary key'),
      );
    });

    test('a text bound shortened', () {
      final after = withColumn(
        Tables.tags,
        'notes',
        (c) => respec(c, bound: const TextBound(maxLength: 10)),
      );
      expect(
        () => check(tableSpecs, after),
        refuses(
          'Tags.notes accepted up to 10000 characters when major 99 '
          'began and accepts 10 now',
        ),
      );
    });

    test('a text shape changed', () {
      final after = withColumn(
        Tables.tags,
        'notes',
        (c) => respec(
          c,
          bound: const TextBound(maxLength: 10000, shape: TextShape.identifier),
        ),
      );
      expect(
        () => check(tableSpecs, after),
        refuses(
          'Tags.notes had shape free when major 99 began and has '
          'identifier now',
        ),
      );
    });

    test('a numeric minimum raised', () {
      final after = withColumn(
        Tables.tags,
        'frequency_mhz',
        (c) => respec(c, numericBound: const NumericBound(min: 100, max: 1000)),
      );
      expect(
        () => check(tableSpecs, after),
        refuses(
          'Tags.frequency_mhz accepted values down to 30.0 when major 99 '
          'began and refuses below 100.0 now',
        ),
      );
    });

    test('a numeric minimum made exclusive at the same value', () {
      final after = withColumn(
        Tables.tags,
        'frequency_mhz',
        (c) => respec(
          c,
          numericBound: const NumericBound(
            min: 30,
            max: 1000,
            minIsExclusive: true,
          ),
        ),
      );
      expect(
        () => check(tableSpecs, after),
        refuses('refuses below 30.0 (exclusive) now'),
      );
    });

    test('a numeric maximum lowered', () {
      final after = withColumn(
        Tables.tags,
        'frequency_mhz',
        (c) => respec(c, numericBound: const NumericBound(min: 30, max: 500)),
      );
      expect(
        () => check(tableSpecs, after),
        refuses(
          'Tags.frequency_mhz accepted values up to 1000.0 when major 99 '
          'began and refuses above 500.0 now',
        ),
      );
    });

    test('a bound added where there was none', () {
      // Unbounded → bounded is the tightest possible tightening.
      final before = withColumn(
        Tables.tags,
        'frequency_mhz',
        (c) => respec(c, numericBound: NumericBound.unbounded),
      );
      expect(
        () => check(before, tableSpecs),
        refuses('Tags.frequency_mhz accepted values down to -∞'),
      );
    });

    test('a NOT NULL column added to a table older builds write', () {
      final after = withAdded(
        Tables.tags,
        const ColumnSpec(
          'collar_serial',
          ColumnType.text,
          nullable: false,
          bound: TextBound.name,
        ),
      );
      expect(
        () => check(tableSpecs, after),
        refuses(
          'Tags.collar_serial is a NOT NULL column added since major 99 '
          'began',
        ),
      );
    });
  });

  group('every compatible change in the table is allowed', () {
    test('a nullable column added', () {
      final after = withAdded(
        Tables.tags,
        const ColumnSpec(
          'collar_serial',
          ColumnType.text,
          bound: TextBound.name,
        ),
      );
      expect(() => check(tableSpecs, after), returnsNormally);
    });

    test('a table added', () {
      final after = [
        ...tableSpecs,
        const TableSpec('Recoveries', [
          ColumnSpec(
            'recovery_id',
            ColumnType.text,
            primaryKey: true,
            bound: TextBound.identifier,
          ),
        ]),
      ];
      expect(() => check(tableSpecs, after), returnsNormally);
    });

    test('a text bound lengthened', () {
      final after = withColumn(
        Tables.tags,
        'notes',
        (c) => respec(c, bound: const TextBound(maxLength: 20000)),
      );
      expect(() => check(tableSpecs, after), returnsNormally);
    });

    test('a numeric range widened, and a bound removed', () {
      final wider = withColumn(
        Tables.tags,
        'frequency_mhz',
        (c) => respec(c, numericBound: const NumericBound(min: 1, max: 5000)),
      );
      expect(() => check(tableSpecs, wider), returnsNormally);
      final unbounded = withColumn(
        Tables.tags,
        'frequency_mhz',
        (c) => respec(c, numericBound: NumericBound.unbounded),
      );
      expect(() => check(tableSpecs, unbounded), returnsNormally);
    });

    test('nothing changed at all', () {
      expect(() => check(tableSpecs, tableSpecs), returnsNormally);
    });
  });

  group('the freeze itself is checked', () {
    test('a major with no freeze fails, naming the tool to run', () {
      expect(
        () => assertWireShapeCompatibleWithMajor(
          major: 98,
          freezes: const {},
          firstMinors: const {98: 40},
        ),
        refuses('No frozen wire shape for schema major 98'),
      );
    });

    test('a freeze not taken at the major\'s first minor fails', () {
      expect(
        () => assertWireShapeCompatibleWithMajor(
          major: 99,
          freezes: {99: freezeWireShape(major: 99, schemaVersion: 51)},
          firstMinors: const {99: 50},
        ),
        refuses(
          'says it was taken at schema v51, but schemaMajorFirstMinor '
          'says major 99 begins at v50',
        ),
      );
    });
  });
}

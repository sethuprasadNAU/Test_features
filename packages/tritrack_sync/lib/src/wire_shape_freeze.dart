/// **The compatibility boundary, made checkable — task 11.242.**
///
/// ## The defect this exists to catch
///
/// `schemaMajorVersion` is the promise that two builds can sync: same major
/// syncs, different major refuses. Until this file, whether a schema change
/// honoured that promise was decided by a person reading a table of nine kinds
/// of change in `TriTrack_Technical_Context.md` and deciding which row theirs
/// was in. Task 11.240 made `Tags.color_hex` nullable — a column that every
/// shipped build stored `NOT NULL` — and read it as additive. It was not: a
/// v15 phone handed a v16 row refuses it at its own database, the page rolls
/// back, the cursor never moves, and the phone reports a fault in itself for
/// as long as it lives (`test/data/sync/v15_device_meets_v16_row_test.dart`
/// in the app holds the measurement). **Nothing noticed, because the rule was
/// prose.** This file is the rule as something that can refuse.
///
/// ## How it works
///
/// When a major is spent, the wire's shape is **frozen**: every table in
/// `Tables.all`, every column, and the four facts about a column that an
/// older build depends on — its type, whether it is `NOT NULL`, whether it is
/// in the primary key, and the bound its value must satisfy. The freeze is
/// written to `wire_shape_freezes.dart` by `tool/freeze_wire_shape.dart` and
/// keyed by the major it was taken at. [assertWireShapeCompatibleWithMajor]
/// then compares the *current* declaration against the freeze for the
/// *current* major, and throws on any difference an older build on that major
/// could not survive:
///
/// | Change since the freeze | Older build on the same major... | Verdict |
/// |---|---|---|
/// | a table gone from the wire | keeps re-sending rows nobody wants | **refuse** |
/// | a column gone | keeps showing and re-sending it | **refuse** (delete or rename — indistinguishable from here) |
/// | a column's type changed | sends the wrong type | **refuse** |
/// | `NOT NULL` → nullable | refuses every row carrying null (**the 11.240 case**) | **refuse** |
/// | nullable → `NOT NULL` | may send null and is now refused for it | **refuse** |
/// | primary key changed | keys rows differently; last-write-wins merges the wrong pairs | **refuse** |
/// | a bound tightened | rows it wrote yesterday are refused unexplained today | **refuse** |
/// | a bound loosened | may drop a row it does not recognise, and says so (task 10.18) | allowed |
/// | a text shape changed | neither tighter nor looser in general | **refuse** — argue it here if a case is |
/// | a new column, nullable | holds and returns it untouched (`UnknownColumnStore`) | allowed |
/// | a new column, `NOT NULL` | omits it, and the server's `NOT NULL` refuses the row | **refuse** |
/// | a new table | ignores it | allowed |
///
/// A refusal names the table, the column, both values and the remedy: undo the
/// change, or bump `schemaMajorVersion` and freeze again — which is the
/// decision the table above used to leave to whoever happened to be reading.
///
/// ## What it cannot see, written down so nobody assumes it can
///
/// - **The same name given a new meaning.** Both builds accept every value and
///   the data is silently wrong. No declaration can carry "meaning", which is
///   why the technical document marks this row *undetectable* and standing
///   rule 2 forbids it outright: if the meaning changes, the name changes —
///   and then this check sees a deleted column.
/// - **Closed enum sets.** `RowValidator` checks `status`, `role`, `sex` and
///   the like against sets written into its own `switch`, not into
///   `ColumnSpec`, so a value removed from one of those enums is a tightened
///   rule this file does not know about. The trip-wire: if that happens once,
///   move the sets onto the column declaration and add them to the freeze.
/// - **Tables outside `Tables.all`.** `Tag_Library`, the held and dropped
///   row stores and the unknown-column store never cross the wire, and are
///   deliberately out of scope.
/// - **Whether the freeze was taken honestly.** A person who bumps the major,
///   changes the schema further, and then freezes has frozen the changed
///   shape, and that is correct — the bump covers it. What the check does
///   require is that the freeze for a major was taken at that major's first
///   minor (`schemaMajorFirstMinor`), so the two declarations cannot drift.
///
/// ## Why a frozen copy is not the hand-kept list this project forbids
///
/// It is a copy on purpose. The question "what did the wire look like when
/// this major began" has no other source inside the build — the old
/// declaration is gone, and reading it back out of git would put a commit
/// hash somewhere a person has to maintain. A freeze fails in the visible
/// direction: stale means a red build naming the exact difference, never a
/// silent pass. Its only maintenance is at a major bump, where the failure
/// message says what to run. The same posture as `gate_c_baseline.py`.
library;

import 'schema_constants.dart';
import 'table_columns.dart';
import 'wire_shape_freezes.dart';

export 'wire_shape_freezes.dart' show frozenWireShapes;

/// One column as an older build on this major remembers it.
class FrozenColumn {
  const FrozenColumn(
    this.name,
    this.type, {
    required this.notNull,
    required this.primaryKey,
    this.maxLength,
    this.shape,
    this.min,
    this.max,
    this.minIsExclusive = false,
  });

  final String name;
  final ColumnType type;

  /// [TableSpec.isNotNull]'s answer — a primary-key column counts as NOT NULL
  /// whatever its own flag says, for the reason given there.
  final bool notNull;
  final bool primaryKey;

  /// Text columns: the length cap and shape a value had to satisfy.
  final int? maxLength;
  final TextShape? shape;

  /// Numeric columns: the range. Null means unbounded on that side.
  final double? min;
  final double? max;
  final bool minIsExclusive;

  /// Reads a live declaration into a frozen one.
  factory FrozenColumn.of(TableSpec table, ColumnSpec column) => FrozenColumn(
    column.name,
    column.type,
    notNull: table.isNotNull(column),
    primaryKey: column.primaryKey,
    maxLength: column.bound?.maxLength,
    shape: column.bound?.shape,
    min: column.numericBound?.min,
    max: column.numericBound?.max,
    minIsExclusive: column.numericBound?.minIsExclusive ?? false,
  );
}

/// One wire table's columns, frozen.
class FrozenTable {
  const FrozenTable(this.name, this.columns);
  final String name;
  final List<FrozenColumn> columns;
}

/// The whole wire, frozen at the moment a major began.
class FrozenWireShape {
  const FrozenWireShape({
    required this.major,
    required this.schemaVersion,
    required this.tables,
  });

  /// The [schemaMajorVersion] this freeze belongs to.
  final int major;

  /// The [latestSchemaVersion] at which it was taken — must equal
  /// `schemaMajorFirstMinor[major]`, asserted below.
  final int schemaVersion;
  final List<FrozenTable> tables;
}

/// Freezes [specs] (default: the live `tableSpecs`) as they stand.
FrozenWireShape freezeWireShape({
  List<TableSpec>? specs,
  int? major,
  int? schemaVersion,
}) => FrozenWireShape(
  major: major ?? schemaMajorVersion,
  schemaVersion: schemaVersion ?? latestSchemaVersion,
  tables: [
    for (final table in specs ?? tableSpecs)
      FrozenTable(table.name, [
        for (final column in table.columns) FrozenColumn.of(table, column),
      ]),
  ],
);

/// The instruction every refusal ends with.
String _remedy(int major) =>
    'Either undo the change, or — if it is intended — bump schemaMajorVersion '
    'in schema_constants.dart, add the new major to schemaMajorFirstMinor, and '
    'run `dart run tool/freeze_wire_shape.dart` in packages/tritrack_sync to '
    'freeze the wire at major ${major + 1}. A bump strands every device in the '
    'field until it updates; see "Standing rules for schema evolution" in '
    'TriTrack_Technical_Context.md before spending one.';

/// Throws a [StateError] naming the first way the live declaration has drifted
/// from the freeze for the current major in a direction an older build on
/// that major cannot survive — see the table in this library's comment.
///
/// [specs], [major], [freezes] and [firstMinors] exist so a test can hand it
/// a doctored declaration and watch it refuse; production callers pass
/// nothing. Called from the package's own tests, from the app suite (so the
/// pre-commit hook sees it) and from the server suite.
void assertWireShapeCompatibleWithMajor({
  List<TableSpec>? specs,
  int? major,
  Map<int, FrozenWireShape>? freezes,
  Map<int, int>? firstMinors,
}) {
  final current = major ?? schemaMajorVersion;
  final live = specs ?? tableSpecs;
  final table = freezes ?? frozenWireShapes;
  final starts = firstMinors ?? schemaMajorFirstMinor;

  final frozen = table[current];
  if (frozen == null) {
    throw StateError(
      'No frozen wire shape for schema major $current. Every major from 4 on '
      'is frozen at the moment it begins, so that a later change to a shared '
      "table's columns can be checked against what devices on this major "
      'already store. Run `dart run tool/freeze_wire_shape.dart` in '
      'packages/tritrack_sync and commit wire_shape_freezes.dart.',
    );
  }
  final expectedStart = starts[current];
  if (frozen.schemaVersion != expectedStart) {
    throw StateError(
      'The frozen wire shape for major $current says it was taken at schema '
      'v${frozen.schemaVersion}, but schemaMajorFirstMinor says major $current '
      'begins at v$expectedStart. The two declarations have drifted; fix '
      'whichever is wrong.',
    );
  }

  final liveByName = {for (final t in live) t.name: t};

  for (final frozenTable in frozen.tables) {
    final liveTable = liveByName[frozenTable.name];
    if (liveTable == null) {
      throw StateError(
        '${frozenTable.name} was on the wire when major $current began and is '
        'not declared now. A device on major $current keeps that table and '
        'keeps offering its rows, which the server can no longer store — '
        'deleting a table is a major bump. ${_remedy(current)}',
      );
    }
    final liveColumns = {for (final c in liveTable.columns) c.name: c};

    for (final was in frozenTable.columns) {
      final now = liveColumns[was.name];
      final at = '${frozenTable.name}.${was.name}';
      if (now == null) {
        throw StateError(
          '$at was on the wire when major $current began and is not declared '
          'now. A device on major $current keeps showing and re-sending it — '
          'and if it was renamed, both builds now maintain the same fact under '
          'two names. Deleting or renaming a column is a major bump. '
          '${_remedy(current)}',
        );
      }
      if (now.type != was.type) {
        throw StateError(
          '$at was ${was.type.name} when major $current began and is '
          '${now.type.name} now. A device on major $current sends the old '
          'type. Retyping a column is a major bump. ${_remedy(current)}',
        );
      }
      final isNotNullNow = liveTable.isNotNull(now);
      if (was.notNull && !isNotNullNow) {
        throw StateError(
          '$at was NOT NULL when major $current began and is nullable now. '
          'A device on major $current stores it NOT NULL, so the first row a '
          'newer build sends with null in it is refused by that device\'s own '
          'database, the page rolls back, and its sync never advances again — '
          'while it reports a fault in itself. This is what task 11.240 did '
          'to Tags.color_hex and what task 11.242 exists because of. Relaxing '
          'NOT NULL is a major bump. ${_remedy(current)}',
        );
      }
      if (!was.notNull && isNotNullNow) {
        throw StateError(
          '$at was nullable when major $current began and is NOT NULL now. '
          'A device on major $current may send null, and the server now '
          'refuses a row it accepted yesterday, unexplained. Tightening a '
          'rule is a major bump. ${_remedy(current)}',
        );
      }
      if (now.primaryKey != was.primaryKey) {
        throw StateError(
          '$at ${was.primaryKey ? 'was' : 'was not'} part of the primary key '
          'when major $current began and ${now.primaryKey ? 'is' : 'is not'} '
          'now. Two builds keying the same rows differently is what last-'
          'write-wins cannot survive — it was the reason for major 2. '
          '${_remedy(current)}',
        );
      }
      _checkBound(at, was, now, current);
    }

    for (final added in liveTable.columns) {
      if (frozenTable.columns.any((c) => c.name == added.name)) continue;
      if (liveTable.isNotNull(added)) {
        throw StateError(
          '${frozenTable.name}.${added.name} is a NOT NULL column added since '
          'major $current began. A device on major $current writes '
          '${frozenTable.name} rows without it, and the server\'s NOT NULL '
          'refuses every one. A column added within a major must be nullable '
          '(standing rule 1: an unused nullable column costs a few bytes; a '
          'major bump costs every device in the field). ${_remedy(current)}',
        );
      }
    }
  }
}

/// A bound may loosen within a major and may not tighten — see the table in
/// the library comment for why the two directions differ.
void _checkBound(String at, FrozenColumn was, ColumnSpec now, int major) {
  final text = now.bound;
  if (was.maxLength != null || text != null) {
    if (text == null) {
      // A bound removed altogether is the loosest possible change; allowed.
      return;
    }
    if (was.maxLength != null && text.maxLength < was.maxLength!) {
      throw StateError(
        '$at accepted up to ${was.maxLength} characters when major $major '
        'began and accepts ${text.maxLength} now. A value a device on major '
        '$major wrote yesterday is refused today, unexplained. Tightening a '
        'bound is a major bump; loosening one is not. ${_remedy(major)}',
      );
    }
    if (was.shape != null && text.shape != was.shape) {
      throw StateError(
        '$at had shape ${was.shape!.name} when major $major began and has '
        '${text.shape.name} now. A shape change is neither strictly tighter '
        'nor looser in general, so it is treated as a rule change. If this '
        'particular one only loosens, say so here and widen this check; '
        'otherwise it is a major bump. ${_remedy(major)}',
      );
    }
  }
  final numeric = now.numericBound;
  if (numeric == null) return;
  final minTightened =
      numeric.min != null &&
      (was.min == null ||
          numeric.min! > was.min! ||
          (numeric.min == was.min &&
              numeric.minIsExclusive &&
              !was.minIsExclusive));
  if (minTightened) {
    throw StateError(
      '$at accepted values down to ${was.min ?? '-∞'}'
      '${was.minIsExclusive ? ' (exclusive)' : ''} when major $major began '
      'and refuses below ${numeric.min}${numeric.minIsExclusive ? ' (exclusive)' : ''} '
      'now. Tightening a bound is a major bump. ${_remedy(major)}',
    );
  }
  final maxTightened =
      numeric.max != null && (was.max == null || numeric.max! < was.max!);
  if (maxTightened) {
    throw StateError(
      '$at accepted values up to ${was.max ?? '+∞'} when major $major began '
      'and refuses above ${numeric.max} now. Tightening a bound is a major '
      'bump. ${_remedy(major)}',
    );
  }
}

/// Renders [freezes] as the Dart source `tool/freeze_wire_shape.dart` writes —
/// kept beside the reader so the two cannot disagree about the encoding.
/// Every major that has a freeze is written, oldest first, so a bump appends
/// to the history rather than replacing it.
String renderFrozenWireShapes(Map<int, FrozenWireShape> freezes) {
  final out = StringBuffer()
    ..writeln(
      '// GENERATED by `dart run tool/freeze_wire_shape.dart` — do not edit.',
    )
    ..writeln('//')
    ..writeln(
      "// The wire's shape at the moment each schema major began. Read by",
    )
    ..writeln(
      '// `assertWireShapeCompatibleWithMajor` (wire_shape_freeze.dart), which',
    )
    ..writeln(
      '// fails a build whose live declaration has drifted from the freeze for',
    )
    ..writeln(
      '// the current major in a way an older build on that major cannot',
    )
    ..writeln('// survive. Regenerated only when the major is bumped.')
    ..writeln()
    ..writeln("import 'table_columns.dart';")
    ..writeln("import 'wire_shape_freeze.dart';")
    ..writeln()
    ..writeln(
      '/// Keyed by major. Majors 1–3 predate the freeze and have no entry;',
    )
    ..writeln('/// their shapes are recoverable from git only.')
    ..writeln('const Map<int, FrozenWireShape> frozenWireShapes = {');
  for (final major in freezes.keys.toList()..sort()) {
    final shape = freezes[major]!;
    out
      ..writeln('  $major: FrozenWireShape(')
      ..writeln('    major: ${shape.major},')
      ..writeln('    schemaVersion: ${shape.schemaVersion},')
      ..writeln('    tables: [');
    for (final table in shape.tables) {
      out.writeln("      FrozenTable('${table.name}', [");
      for (final c in table.columns) {
        final args = <String>[
          'notNull: ${c.notNull}',
          'primaryKey: ${c.primaryKey}',
          if (c.maxLength != null) 'maxLength: ${c.maxLength}',
          if (c.shape != null) 'shape: TextShape.${c.shape!.name}',
          if (c.min != null) 'min: ${c.min}',
          if (c.max != null) 'max: ${c.max}',
          if (c.minIsExclusive) 'minIsExclusive: true',
        ];
        out.writeln(
          "        FrozenColumn('${c.name}', ColumnType.${c.type.name}, "
          '${args.join(', ')}),',
        );
      }
      out.writeln('      ]),');
    }
    out
      ..writeln('    ],')
      ..writeln('  ),');
  }
  out.writeln('};');
  return out.toString();
}

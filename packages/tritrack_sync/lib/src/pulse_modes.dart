/// **A tag's pulse modes — task 11.187.**
///
/// Michael, 2026-09-07: *"There are always two pulse types currently (active
/// and mortality). The truth is that the person who enters the tag should be
/// able to set those, because some tags have only one mode and some have more
/// than one… The user should be able to toggle on/off up to three modes but
/// not fewer than 1."*
///
/// ## The shape, and why it is columns rather than a child table
///
/// The maximum is three and it is fixed, so three name/rate pairs as ordinary
/// `Tags` columns keeps **every existing mechanism working untouched**: the
/// per-column `NumericBound`/`TextBound` the row validator reads, the
/// [TagColumnKind.measurementContext] versioning that already makes a tag edit
/// ask *correction or change*, the totality check on [tagColumnKinds], and the
/// CSV columns. A child `Tag_Modes` table would need a new synced table, new
/// authorization rules, new permissions-matrix rows — and an answer to how a
/// tag *version* snapshots its child rows, which the versioning design does not
/// have. A JSON blob is refused outright: it defeats the per-column bounds the
/// row validator is built on.
///
/// ## Why slot 1's rate column is called `pulse_rate`
///
/// It is the column that has always been there. Renaming it to
/// `pulse_mode_1_rate_bpm` for symmetry is **the one thing that could not be
/// done**: `SyncSchemaVersionException`'s doc lists renaming a column among the
/// changes unknown-column preservation cannot save, so it would cost a
/// [schemaMajorVersion] bump and strand every device in the field. Keeping it
/// and adding a *second* rate column for slot 1 would leave two columns that
/// can disagree, and `Tag_Versions` would have to carry the dead one forever
/// because it holds history.
///
/// So slot 1's rate **is** `pulse_rate`, no value moves, and every existing
/// `Tag_Versions` row keeps meaning exactly what it meant. The asymmetry is
/// declared once, here, in [pulseModeColumns] — every reader derives from it
/// rather than knowing about it.
///
/// ## The unit is beats per minute, everywhere, always
///
/// Michael corrected the planning session on this (2026-09-07): *"Keep them
/// stored as bpm but still allow users to toggle to see them in
/// seconds-per-pulse."* The toggle is a display preference on the device; no
/// stored number is ever in any other unit, so no migration ever has to do
/// arithmetic on one.
library;

import 'schema_constants.dart';
import 'table_columns.dart';
import 'tag_column_kinds.dart';

/// The most modes a tag can have. Fixed, and fixed is what makes the column
/// shape above the cheap answer rather than the lazy one.
const int maxPulseModes = 3;

/// The `Tags` columns holding one mode.
///
/// [rateColumn] is nullable-in-the-database on every slot: a rate is optional
/// (`Pulse rate (bpm, optional)` is what the field has said since the tag form
/// was written), and a tag whose rate nobody measured is a real tag.
class PulseModeColumns {
  const PulseModeColumns({
    required this.slot,
    required this.nameColumn,
    required this.rateColumn,
  });

  /// 1-based, and the number an observation stores. See [PulseModeSlot].
  final int slot;

  /// The column holding this mode's name. **Non-null is what makes the mode
  /// exist**; NULL means the slot is switched off — except on slot 1, where
  /// NULL means "never said" and reads as [defaultPulseModeNames]`[0]`,
  /// because a tag can never have zero modes.
  final String nameColumn;

  /// The column holding this mode's rate in beats per minute, or NULL when
  /// nobody has measured it.
  final String rateColumn;
}

/// The three slots, in order. **The one declaration of which column holds
/// what** — see the library comment for why slot 1's rate is `pulse_rate`.
const List<PulseModeColumns> pulseModeColumns = [
  PulseModeColumns(
    slot: 1,
    nameColumn: 'pulse_mode_1_name',
    rateColumn: 'pulse_rate',
  ),
  PulseModeColumns(
    slot: 2,
    nameColumn: 'pulse_mode_2_name',
    rateColumn: 'pulse_mode_2_rate_bpm',
  ),
  PulseModeColumns(
    slot: 3,
    nameColumn: 'pulse_mode_3_name',
    rateColumn: 'pulse_mode_3_rate_bpm',
  ),
];

/// The columns schema v12 adds, in the order it adds them. Read by the app's
/// and the server's v12 migrations so the three lists cannot disagree about
/// which columns exist; each side still writes its own DDL, because a shipped
/// migration describes the change as it was made.
const List<String> pulseModeColumnsAddedInV12 = [
  'pulse_mode_1_name',
  'pulse_mode_2_name',
  'pulse_mode_2_rate_bpm',
  'pulse_mode_3_name',
  'pulse_mode_3_rate_bpm',
];

/// The names a tag's modes get when nobody has said otherwise — Michael's
/// defaults, 2026-09-07.
///
/// **Only the first two.** A new tag is created with two modes, and slot 3 is
/// empty until somebody turns it on and names it; there is no third default
/// because there is no third thing every collar has.
const List<String> defaultPulseModeNames = ['Normal', 'Mortality'];

/// The rates a **newly created** tag's two default modes get, in beats per
/// minute — Michael's *"'Normal' at 1 pulse per second and Mortality at 2
/// pulses per second"*, converted once, here.
///
/// **These are defaults for a tag being created, never a backfill.** Schema
/// v12's migration writes the two *names* onto every existing tag, because the
/// build those tags were created under offered exactly those two modes and
/// transcribing that is not an invention. It writes **no rate**, because the
/// old schema had one rate column and no place to record a mortality rate — so
/// any number written there would be a measurement nobody took. See
/// `schemaV12Statements`.
const List<double> defaultPulseModeRatesBpm = [60, 120];

/// The word for a mode that has a slot but no name to show — a record that
/// names slot 3 while the `Tag_Versions` row saying what slot 3 was called is
/// not on this device.
///
/// It says what is known (which mode) and does not guess at what is not (its
/// name). Substituting the tag's *current* slot-3 name would be exactly the
/// falsehood task 11.32's version table exists to remove.
String unnamedPulseMode(int slot) => 'Mode $slot';

/// Throws unless every column [pulseModeColumns] names is a real `Tags` column
/// declared [TagColumnKind.measurementContext].
///
/// **Both halves matter and they fail for different reasons.** A name that is
/// not a `Tags` column at all is this file drifting from the schema. A column
/// that is a `Tags` column but is *not* versioned is worse and quieter: the
/// mode would be read live off the tag row, so renaming a mode would
/// retroactively rename it on every bearing ever recorded against it — the
/// whole harm task 11.32 closed, reopened one column at a time.
///
/// Called from tests on both sides of the wire, like
/// [assertEveryTagColumnDeclaresItsKind]. [tagColumns] and [kinds] exist so a
/// test can hand it a doctored declaration and watch it throw: an assertion
/// nobody has seen fail is an assertion nobody knows works.
void assertPulseModeColumnsAreVersioned({
  List<ColumnSpec>? tagColumns,
  Map<String, TagColumnKind>? kinds,
}) {
  final columns = tagColumns ?? tableSpecsByName[Tables.tags]!.columns;
  final declared = kinds ?? tagColumnKinds;
  final actual = {for (final c in columns) c.name};

  if (pulseModeColumns.length != maxPulseModes) {
    throw StateError(
      'pulseModeColumns declares ${pulseModeColumns.length} slots but '
      'maxPulseModes is $maxPulseModes. The two are the same fact.',
    );
  }

  for (final mode in pulseModeColumns) {
    for (final column in [mode.nameColumn, mode.rateColumn]) {
      if (!actual.contains(column)) {
        throw StateError(
          'Pulse mode slot ${mode.slot} names ${Tables.tags}.$column, which '
          'that table does not have. pulse_modes.dart and the schema have '
          'drifted — see pulseModeColumns.',
        );
      }
      if (declared[column] != TagColumnKind.measurementContext) {
        throw StateError(
          '${Tables.tags}.$column holds a pulse mode but is declared '
          '${declared[column]}, not TagColumnKind.measurementContext. A mode '
          'read live off the tag row would rename itself on every bearing ever '
          'recorded against it, which is the harm Tag_Versions exists to '
          'prevent. See tag_column_kinds.dart.',
        );
      }
    }
  }
}

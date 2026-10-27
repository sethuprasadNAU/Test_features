import 'csv_writer.dart';

import '../models/actual_tag_location.dart';
import '../models/tag.dart';
import '../models/tag_version.dart';
import '../models/user.dart';

/// CSV export of ground-truth points — where somebody physically found the
/// animal, the collar, or both (task 11.33's records, given a way out of the
/// device by task 11.92).
///
/// **These are the yardstick, not more measurements**, so they export as their
/// own file rather than as extra rows in `observations.csv`: a spreadsheet that
/// mixed estimates and truth in one table would invite scoring a bearing
/// against itself.
///
/// ## The two tag-name columns, and why both are here
///
/// `tag_name` is what the collar was called **when somebody walked in and found
/// it**, read from the `Tag_Versions` row the point recorded (task 11.32).
/// `tag_current_name` is what it is called **now**. Renaming a tag is ordinary —
/// "148.520" becomes "F-07 Juniper" once the animal has a name — and after such
/// a rename the two columns disagree on purpose: the first is what makes an
/// export made last month line up with this one, the second is what the person
/// reading it recognises. Neither is redundant and neither is reconciled here.
///
/// ## `found_by` and `position_source`, added by task 11.93
///
/// `found_by` is **who walked in and found the collar**, which is not the same
/// person as whoever last edited the row and is never taken from that column.
/// `position_source` says whether the coordinate is a GPS fix, a hand-placed
/// pin, or a fix somebody later moved by hand — a distinction the precision
/// radius has never carried, and one that became necessary the moment the
/// position became editable. Both are empty on a point recorded before schema
/// v11, which is the true answer for a row nobody asked either question of.
///
/// A point whose tag has no version history (a tag created before schema v9, or
/// a point that arrived from a device whose version row has not synced) exports
/// `tag_values_recorded` as `no` and leaves the recorded columns **empty**. An
/// empty cell says "we do not know what this collar was called then", which is
/// true; filling it from today's tag row would state a name nobody recorded.
///
/// ## `found_kind`, and the rule that travels with it
///
/// Michael's decision of 2026-08-31: any figure of the form *"estimates were
/// accurate to within X metres"* counts **`animal_and_collar` points only by
/// default**, with the other kinds included only deliberately, and whatever
/// screen shows such a figure must say which kinds it counted. A `collar_only`
/// point may be where the collar was shed days before, so scoring an estimate
/// against it reports this app as wrong when it was right. **Nothing in the app
/// computes such a number yet**, which is precisely why the column is exported
/// verbatim: whoever does the arithmetic in R needs to be able to make that
/// split themselves.
abstract final class ActualTagLocationCsv {
  static const _header = [
    'location_id',
    // **Who walked in and found it** (task 11.93). Empty means the point was
    // recorded before the app stored a finder — never "unknown person", and
    // never filled in from whoever last edited the row, which is a different
    // fact. A point whose finder this device does not hold exports the raw id
    // rather than a blank, so the two cases stay distinguishable in the file.
    'found_by',
    // What the collar was called when the point was taken — see the class doc.
    'tag_name',
    'tag_frequency_mhz',
    // Whether the two above are known at all: `yes` or `no`, never blank.
    'tag_values_recorded',
    // What it is called now, so a rename is visible rather than invisible.
    'tag_current_name',
    'tag_current_frequency_mhz',
    // `animal_and_collar`, `animal_only` or `collar_only` — the column that
    // decides what the point means. Empty only for a row written before
    // schema v10, where nobody was asked.
    'found_kind',
    'timestamp_local',
    'timestamp_utc',
    'timezone_offset',
    'latitude',
    'longitude',
    // `gps_fix`, `manual_pin`, `gps_fix_adjusted` (a fix somebody later moved
    // by hand) or `manual_entry`. Empty for a point written before schema v11,
    // where the source is genuinely not recorded — **the precision radius does
    // not carry this distinction and never did**, which is why the column
    // exists. Task 11.93.
    'position_source',
    // The radius, in metres, within which the finder claims the position is
    // known. Prefilled from the device's GPS accuracy **when the point was
    // recorded on a GPS fix** and routinely corrected by hand afterwards; for a
    // point placed on the map nothing is prefilled, because a pin's precision
    // is not the phone's. Never blank: a truth point cannot be saved without it.
    'precision_m',
    'notes',
  ];

  /// [recordedStates] maps `location_id` to what the point was recorded
  /// against — build it with `TagVersionRepository.recordedStatesForRows`. A
  /// point missing from the map exports its recorded columns empty and
  /// `tag_values_recorded` as `no`, exactly as `ObservationCsv` does and for
  /// the same reason: **the export never falls back to the tag's current
  /// values**, or a caller who forgot to pass this would silently reintroduce
  /// the whole defect.
  static String export(
    List<ActualTagLocation> locations, {
    required Map<String, Tag> tagsById,
    required Map<String, User> usersById,
    Map<String, RecordedTagState> recordedStates = const {},
  }) {
    final rows = <List<dynamic>>[_header];
    for (final l in locations) {
      final tag = tagsById[l.tagId];
      final recorded = recordedStates[l.locationId];
      final finder = l.userId == null ? null : usersById[l.userId];
      rows.add([
        l.locationId,
        // Three distinct answers, kept distinct: a name; the raw id, when the
        // point names a finder whose `Users` row has not reached this device;
        // and empty, when no finder was ever recorded.
        l.userId == null
            ? null
            : (finder == null
                  ? l.userId
                  : '${finder.firstName} ${finder.lastName}'),
        recorded?.recordedTagName,
        recorded?.recordedFrequencyMhz,
        (recorded?.isRecorded ?? false) ? 'yes' : 'no',
        tag?.tagName ?? l.tagId,
        tag?.frequencyMhz,
        l.foundKind?.db,
        l.timestampLocal.toIso8601String(),
        l.timestampUtc.toIso8601String(),
        l.timezoneOffset,
        l.latitude,
        l.longitude,
        l.positionSource?.db,
        l.uncertaintyRadius,
        l.notes,
      ]);
    }
    return SpreadsheetSafeCsv.encode(rows);
  }
}

import 'wmm.dart';

/// **The declination a map beside the record form draws a compass bearing
/// with** — the manual override if one is set, else the World Magnetic Model
/// at [latitude], [longitude] on [date], else null while the model is still
/// loading.
///
/// It mirrors the save path in `observation_logging_screen.dart`: the
/// override wins over the model there too, and is recorded as `manual`. The
/// save path awaits the model; a map cannot, so null here means *draw the
/// magnetic bearing until the model arrives* — the answer Preview has given
/// since design ask #16.
///
/// **One function because two screens draw from it** (task 11.315). Preview
/// and *Take on map* both turn a magnetic heading into a line on a map, and
/// the second was built to convert "the way Preview does". Two copies of
/// three lines is how the two would come to disagree about where north is.
double? recordDeclinationDeg({
  required double? manualOverrideDeg,
  required WmmService? wmm,
  required double latitude,
  required double longitude,
  required DateTime date,
}) {
  if (manualOverrideDeg != null) return manualOverrideDeg;
  return wmm?.declinationDegrees(
    latitude: latitude,
    longitude: longitude,
    date: date,
  );
}

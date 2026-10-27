import 'package:tritrack_sync/tritrack_sync.dart';

/// **A time zone in plain words** (task 11.331) — what the project form and
/// its confirmation show instead of an IANA name.
///
/// - A place zone: *"Phoenix time (UTC−7), no daylight saving"*, or
///   *"Denver time (UTC−7; UTC−6 with daylight saving)"*.
/// - A sea zone: *"UTC−7, sea time zone, no daylight saving"* — **never its
///   raw name**, because `Etc/GMT+7` means UTC−7 and anyone reading it would
///   take it for the opposite.
///
/// Offsets are read over [year] (this year by default), so the words say what
/// the zone's clock does now, not in 1970.
String describeTimeZone(String zone, {int? year}) {
  final y = year ?? DateTime.now().year;
  if (zone == 'UTC' || zone == 'Etc/UTC' || zone == 'Etc/GMT') {
    return 'UTC, no daylight saving';
  }
  final sea = RegExp(r'^Etc/GMT([+-])(\d{1,2})$').firstMatch(zone);
  if (sea != null) {
    final hours = int.parse(sea.group(2)!);
    // The name's sign is inverted: Etc/GMT+7 is seven hours BEHIND UTC.
    final offset = Duration(hours: sea.group(1) == '+' ? -hours : hours);
    return '${formatUtcOffset(offset)}, sea time zone, no daylight saving';
  }
  final standard = <Duration>{};
  final daylight = <Duration>{};
  for (var m = 1; m <= 12; m++) {
    final at = DateTime.utc(y, m, 15);
    final offset = FieldTimeZone.offsetAt(zone, at);
    if (offset == null) return zone;
    (FieldTimeZone.isDstAt(zone, at)! ? daylight : standard).add(offset);
  }
  final place = zone.split('/').last.replaceAll('_', ' ');
  final base = standard.isNotEmpty ? standard.first : daylight.first;
  if (daylight.isEmpty || standard.isEmpty) {
    return '$place time (${formatUtcOffset(base)}), no daylight saving';
  }
  return '$place time (${formatUtcOffset(base)}; '
      '${formatUtcOffset(daylight.first)} with daylight saving)';
}

/// `UTC−7`, `UTC+5:30`, `UTC` — with a true minus sign.
String formatUtcOffset(Duration offset) {
  if (offset == Duration.zero) return 'UTC';
  final sign = offset.isNegative ? '−' : '+';
  final minutes = offset.inMinutes.abs();
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? 'UTC$sign$h' : 'UTC$sign$h:${m.toString().padLeft(2, '0')}';
}

/// Every zone a person may pick by hand: the place zones the tz database
/// names (no legacy aliases), then the 25 sea zones, sea zones described in
/// plain words by [describeTimeZone] wherever they are shown.
List<String> pickableTimeZones() {
  const regions = {
    'Africa',
    'America',
    'Antarctica',
    'Asia',
    'Atlantic',
    'Australia',
    'Europe',
    'Indian',
    'Pacific',
  };
  final places = [
    for (final name in FieldTimeZone.allNames)
      if (name.contains('/') && regions.contains(name.split('/').first)) name,
  ]..sort();
  final sea = [
    for (var h = -12; h <= 12; h++)
      h == 0 ? 'Etc/GMT' : (h < 0 ? 'Etc/GMT+${-h}' : 'Etc/GMT-$h'),
  ];
  return [...places, ...sea];
}

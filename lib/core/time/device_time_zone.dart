import 'dart:io' show Platform;

import 'package:tritrack_sync/tritrack_sync.dart';

/// **This phone's own time zone, as an IANA name** — the default for a new
/// project with no area yet (task 11.331), and the zone the v20 migration
/// gives a deployment row whose days were plainly typed on this phone.
///
/// ## Why it is worked out rather than asked for
///
/// Dart reports the phone's offset for any date, and an abbreviation such as
/// `MST`, but not the zone's IANA name; getting the name would take a native
/// plugin, which is a new dependency with platform code for a value the
/// creator confirms anyway (Security Model §3.8 records the choice). So:
///
/// 1. **`TZ`, when the process has one** (a developer machine, the test
///    suite, the nightly check's three-zone matrix) and it names a known
///    zone — that is exact.
/// 2. **Otherwise, the zone whose clock matches this phone's on every day of
///    the year** — the offset at noon UTC on each of the 365 days, so a
///    daylight-saving change on a different date tells two zones apart (the
///    United States and Europe change on different weekends; Mexico stopped
///    changing in 2022). Several zones can match exactly (Denver, Boise and
///    Edmonton keep one clock); a short list of the most-used zone for each
///    clock breaks the tie, then the abbreviation, then the name. **Zones that
///    match on every day of this year read every day of this year
///    identically**, which is what a deployment day needs; only the name the
///    screen shows can differ, and the creator sees it and can change it.
/// 3. **Null** when nothing matches (an unusual device setting): the caller
///    falls back to reading days in the phone's own zone, as before v20.
String? deviceTimeZone({DateTime? now}) {
  final fromEnv = _fromEnvironment();
  if (fromEnv != null) return fromEnv;
  final year = (now ?? DateTime.now()).year;
  final samples = <int>[
    for (var d = 0; d < 365; d++)
      DateTime.utc(year, 1, 1 + d, 12).millisecondsSinceEpoch,
  ];
  final offsets = [
    for (final ms in samples)
      DateTime.fromMillisecondsSinceEpoch(ms).timeZoneOffset,
  ];
  final matches = <String>[];
  for (final name in FieldTimeZone.allNames) {
    if (!_isPlaceName(name)) continue;
    final loc = FieldTimeZone.location(name)!;
    var same = true;
    for (var i = 0; i < samples.length; i++) {
      if (loc.timeZone(samples[i]).offset != offsets[i]) {
        same = false;
        break;
      }
    }
    if (same) matches.add(name);
  }
  if (matches.isEmpty) return _wholeHourSeaZone(offsets.first);
  for (final preferred in _mostUsed) {
    if (matches.contains(preferred)) return preferred;
  }
  final abbreviation = DateTime.fromMillisecondsSinceEpoch(
    samples.first,
  ).timeZoneName;
  final byAbbreviation = [
    for (final name in matches)
      if (FieldTimeZone.location(name)!.timeZone(samples.first).abbreviation ==
          abbreviation)
        name,
  ];
  final pool = byAbbreviation.isNotEmpty ? byAbbreviation : matches;
  pool.sort();
  return pool.first;
}

String? _fromEnvironment() {
  String? raw;
  try {
    raw = Platform.environment['TZ'];
  } catch (_) {
    return null;
  }
  if (raw == null || raw.isEmpty) return null;
  final name = raw.startsWith(':') ? raw.substring(1) : raw;
  return FieldTimeZone.isKnown(name) ? name : null;
}

/// A zone named for a place (`America/Phoenix`), not a legacy alias such as
/// `MST7MDT` or `US/Arizona`, nor a sea zone.
bool _isPlaceName(String name) {
  final slash = name.indexOf('/');
  if (slash < 0) return false;
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
  return regions.contains(name.substring(0, slash));
}

String? _wholeHourSeaZone(Duration offset) {
  if (offset.inMinutes % 60 != 0) return null;
  final hours = offset.inHours;
  if (hours == 0) return 'Etc/GMT';
  if (hours.abs() > 14) return null;
  return hours > 0 ? 'Etc/GMT-$hours' : 'Etc/GMT+${-hours}';
}

/// The most-used zone for each common clock, so a phone in Colorado is
/// offered "Denver", not the alphabetically first of the zones that keep
/// Denver's clock. Order matters only between zones with the same clock.
const _mostUsed = [
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Phoenix',
  'America/Los_Angeles',
  'America/Anchorage',
  'Pacific/Honolulu',
  'America/Halifax',
  'America/St_Johns',
  'America/Mexico_City',
  'America/Bogota',
  'America/Lima',
  'America/Santiago',
  'America/Sao_Paulo',
  'America/Argentina/Buenos_Aires',
  'Europe/London',
  'Europe/Berlin',
  'Europe/Paris',
  'Europe/Helsinki',
  'Europe/Moscow',
  'Africa/Lagos',
  'Africa/Johannesburg',
  'Africa/Nairobi',
  'Asia/Dubai',
  'Asia/Kolkata',
  'Asia/Bangkok',
  'Asia/Shanghai',
  'Asia/Tokyo',
  'Australia/Perth',
  'Australia/Brisbane',
  'Australia/Adelaide',
  'Australia/Sydney',
  'Pacific/Auckland',
];

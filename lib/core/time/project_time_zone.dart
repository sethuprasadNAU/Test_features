import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/models/project.dart';
import 'device_time_zone.dart';
import 'time_zone_boundaries.dart';

/// Where a project's zone came from, so the form can say so in plain words.
enum TimeZoneSource {
  /// The zone at the center of the project's area.
  areaCenter,

  /// This phone's zone, because the project has no area yet.
  thisPhone,

  /// Stored on the project — chosen at creation or since.
  project,
}

/// The zone the center of [project]'s area falls in, or null when it has no
/// area (or the boundaries cannot be read — the caller then falls back to the
/// phone's zone).
Future<String?> areaCenterTimeZone(Project project) async {
  final center = project.areaCenter;
  if (center == null) return null;
  return zoneAtPlace(center.latitude, center.longitude);
}

/// **The zone a project's new deployment days are written in** — its stored
/// zone when this build knows it, otherwise the zone at the center of its
/// area, otherwise this phone's (task 11.331). The fallbacks exist for a
/// project row from a build older than schema v20, which carries none; every
/// device derives the same answer from the same area.
///
/// Null only when none of the three can be had (no area, and a phone whose
/// clock matches no named zone): days are then read in the phone's own zone,
/// as they were before v20.
Future<String?> effectiveProjectTimeZone(Project project) async {
  final stored = project.timeZone;
  if (FieldTimeZone.isKnown(stored)) return stored;
  return await areaCenterTimeZone(project) ?? deviceTimeZone();
}

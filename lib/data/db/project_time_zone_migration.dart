import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../core/time/device_time_zone.dart';
import '../../core/time/time_zone_boundaries.dart';
import 'schema.dart';

/// Schema v20 (task 11.331): every project gets a time zone, and every
/// deployment row the zone its days were written in — and it prints what it
/// decided.
///
/// ## What each existing row is given
///
/// - **A project:** the zone at the center of its area (a sea zone at sea),
///   or this phone's zone when it has no area. Never rewritten if it already
///   has one.
/// - **A deployment:** its project's zone — **unless its dates plainly were
///   typed on this phone in another zone.** Until v20 a day was stored as
///   midnight on the phone that typed it. A row whose dates sit at this
///   phone's midnight but not at the project zone's (Michael entering an
///   Arizona project's collars from London) would, given the project's zone,
///   turn every day into a time on the evening before — the day a person
///   typed would change. Such a row gets **this phone's zone**, so its days
///   stay the days that were typed, and it is counted and listed by id.
///   The plan asked for every row to take the project's zone and for the odd
///   ones to be listed; this keeps the listing and declines to change what
///   those rows say. Task 11.331's report names the deviation.
/// - A row with no dates, or whose dates already sit at the project zone's
///   midnight or carry a swap time, simply takes the project's zone.
///
/// **No sync stamp moves.** These are backfills of a new column on this
/// device, not edits: nothing is pushed because of them, and the server's
/// copies keep a null zone until the row is next edited. Every reader treats
/// a null zone the way the build that wrote the row did (`FieldTimeZone`).
abstract final class ProjectTimeZoneMigration {
  // ignore: avoid_print
  static void _print(String line) => print(line);

  /// Applies schema v20. Called from the migration list; not for direct use.
  ///
  /// A fresh create (`fromVersion == 0`) has no rows and prints nothing; an
  /// upgrade always prints, including one that finds nothing.
  static Future<void> apply(
    DatabaseExecutor db,
    int fromVersion, {
    void Function(String line) log = _print,
  }) async {
    final report = await backfill(db);
    if (fromVersion > 0) {
      for (final line in report.report()) {
        log(line);
      }
    }
  }

  /// Runs the v20 statements and decides each row's zone. Public so a test
  /// can assert the census rather than read it out of a log.
  ///
  /// [zoneAt] and [phoneZone] are the two outside facts the decision needs;
  /// tests pass their own. By default the zone at a place is read from the
  /// bundled boundaries (null if they cannot be loaded, which then falls back
  /// to the phone's zone, and is counted).
  static Future<ProjectTimeZoneReport> backfill(
    DatabaseExecutor db, {
    Future<String?> Function(double latitude, double longitude)? zoneAt,
    String? Function()? phoneZone,
  }) async {
    for (final statement in schemaV20Statements()) {
      await db.execute(statement);
    }
    final lookUp = zoneAt ?? zoneAtPlace;
    final phone = (phoneZone ?? deviceTimeZone)();

    final projects = await db.rawQuery(
      'SELECT project_id, bbox_min_lat, bbox_min_lon, bbox_max_lat, '
      'bbox_max_lon FROM ${Tables.projects} WHERE time_zone IS NULL',
    );
    final projectZones = <String, String?>{};
    var fromArea = 0, fromPhone = 0, noZone = 0;
    for (final row in projects) {
      final minLat = row['bbox_min_lat'] as num?;
      final minLon = row['bbox_min_lon'] as num?;
      final maxLat = row['bbox_max_lat'] as num?;
      final maxLon = row['bbox_max_lon'] as num?;
      String? zone;
      if (minLat != null && minLon != null && maxLat != null && maxLon != null) {
        zone = await lookUp(
          (minLat + maxLat) / 2,
          (minLon + maxLon) / 2,
        );
        if (zone != null) fromArea++;
      }
      if (zone == null && phone != null) {
        zone = phone;
        fromPhone++;
      }
      if (zone == null) noZone++;
      final id = row['project_id'] as String;
      projectZones[id] = zone;
      if (zone != null) {
        await db.update(
          Tables.projects,
          {'time_zone': zone},
          where: 'project_id = ?',
          whereArgs: [id],
        );
      }
    }
    // Projects that already had a zone (none, on a real upgrade) still
    // govern their deployments.
    for (final row in await db.rawQuery(
      'SELECT project_id, time_zone FROM ${Tables.projects} '
      'WHERE time_zone IS NOT NULL',
    )) {
      projectZones.putIfAbsent(
        row['project_id'] as String,
        () => row['time_zone'] as String?,
      );
    }

    final deployments = await db.rawQuery(
      'SELECT deployment_id, project_id, attached_date, removed_date '
      'FROM ${Tables.deployments} WHERE time_zone IS NULL',
    );
    var tookProjectZone = 0;
    final typedInPhoneZone = <String>[];
    var leftWithoutZone = 0;
    for (final row in deployments) {
      final projectZone = projectZones[row['project_id'] as String];
      final ends = [
        DbCodec.decodeUtcOrNull(row['attached_date']),
        DbCodec.decodeUtcOrNull(row['removed_date']),
      ].whereType<DateTime>().toList();
      String? zone = projectZone;
      if (projectZone != null && phone != null && phone != projectZone) {
        final offTheProjectsMidnight = ends.where(
          (e) => deploymentEndHasTime(e, projectZone),
        );
        final typedHere =
            offTheProjectsMidnight.isNotEmpty &&
            offTheProjectsMidnight.every(
              (e) => !deploymentEndHasTime(e, phone),
            );
        if (typedHere) zone = phone;
      }
      final id = row['deployment_id'] as String;
      if (zone == null) {
        leftWithoutZone++;
        continue;
      }
      if (zone == projectZone) {
        tookProjectZone++;
      } else {
        typedInPhoneZone.add(id);
      }
      await db.update(
        Tables.deployments,
        {'time_zone': zone},
        where: 'deployment_id = ? AND project_id = ?',
        whereArgs: [id, row['project_id']],
      );
    }
    return ProjectTimeZoneReport(
      projectsFromArea: fromArea,
      projectsFromPhone: fromPhone,
      projectsWithoutZone: noZone,
      deploymentsWithProjectZone: tookProjectZone,
      deploymentsTypedInPhoneZone: List.unmodifiable(typedInPhoneZone),
      deploymentsWithoutZone: leftWithoutZone,
      phoneZone: phone,
    );
  }
}

/// What the v20 backfill decided, as numbers a test can assert and a log
/// can carry.
class ProjectTimeZoneReport {
  const ProjectTimeZoneReport({
    required this.projectsFromArea,
    required this.projectsFromPhone,
    required this.projectsWithoutZone,
    required this.deploymentsWithProjectZone,
    required this.deploymentsTypedInPhoneZone,
    required this.deploymentsWithoutZone,
    required this.phoneZone,
  });

  /// Projects given the zone at the center of their area.
  final int projectsFromArea;

  /// Projects with no area (or unreadable boundaries), given the phone's.
  final int projectsFromPhone;

  /// Projects left with no zone — no area and a phone clock matching no
  /// named zone. Their days read in the phone's zone, as before.
  final int projectsWithoutZone;

  /// Deployment rows given their project's zone.
  final int deploymentsWithProjectZone;

  /// **The rows the plan asked to be listed**: dates at this phone's
  /// midnight and not at the project zone's, given this phone's zone so the
  /// typed days stay the same. Their ids.
  final List<String> deploymentsTypedInPhoneZone;

  /// Deployment rows whose project has no zone; left null.
  final int deploymentsWithoutZone;

  /// The phone's zone as this migration read it.
  final String? phoneZone;

  List<String> report() => [
    'Schema v20 (time zones): $projectsFromArea project(s) took the zone at '
        'the center of their area, $projectsFromPhone took this phone\'s '
        '(${phoneZone ?? 'unknown'}), $projectsWithoutZone have none.',
    'Schema v20 (time zones): $deploymentsWithProjectZone deployment(s) took '
        'their project\'s zone; ${deploymentsTypedInPhoneZone.length} had '
        'dates at this phone\'s midnight rather than the project\'s and keep '
        'this phone\'s zone so their days do not change'
        '${deploymentsTypedInPhoneZone.isEmpty ? '' : ': ${deploymentsTypedInPhoneZone.join(', ')}'}; '
        '$deploymentsWithoutZone left without a zone.',
  ];
}

import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'sync_meta.dart';

part 'project.freezed.dart';

/// A study project. The optional bounding box (`bbox*`) drives tile/DEM
/// pre-download, later crops the viewshed, and feeds Phase 2/3 features.
/// `datum` is stated explicitly for GIS handoff and defaults to WGS84.
///
/// `coordinateFormat`/`triangulationWindowMinutes` were added in schema v2
/// (Phase 4) — the v1 spec named both as Project Setup fields but the
/// original table didn't carry them.
@freezed
abstract class Project with _$Project {
  const Project._();

  const factory Project({
    required String projectId,
    required String projectName,
    String? description,
    String? notes,
    required String ownerUserId,
    required DateTime creationDate,
    double? bboxMinLat,
    double? bboxMinLon,
    double? bboxMaxLat,
    double? bboxMaxLon,
    @Default('WGS84') String datum,
    @Default(CoordinateFormat.dd) CoordinateFormat coordinateFormat,
    @Default(15) int triangulationWindowMinutes,

    /// Which study this project is a season of (task 11.56, schema v18).
    ///
    /// Shared by every project started from this one, and by this one with
    /// the project it was started from — Ponui 2025 and Ponui 2026 carry one
    /// value. Null on a row written before v18 or by an older device, and
    /// null means *never copied*: read it through [effectiveLineageId], never
    /// directly. Sealed like a tag's — recorded, exported, resolved into
    /// words about another project by nothing (`provenanceColumns`).
    String? lineageId,

    /// When this project was started from another, or null for one created
    /// in place — for schema v9's reason: a date invented for it would be a
    /// claim about a past nobody observed.
    DateTime? copiedAt,

    /// **The field site's time zone** (task 11.331, schema v20) — an IANA
    /// name such as `America/Phoenix`. New deployment days, and the
    /// deployment form's "today", are read in it; each deployment row copies
    /// it into its own `time_zone` when written, so changing it later
    /// rewrites nothing (`CLAUDE.md` standing decision 4).
    ///
    /// Defaults at creation to the zone at the center of the project's area
    /// (a sea zone at sea, never the nearest land), or the creator's phone's
    /// zone when there is no area yet, and the creator confirms it. **Null
    /// on a row from a build older than v20**; readers then derive it from
    /// the area the same way on every device (`projectTimeZoneProvider`).
    String? timeZone,
    required SyncMeta sync,
  }) = _Project;

  /// [lineageId], with null read as this project's own id — which is what
  /// the v18 migration writes for every project that predates it, and true
  /// for the same reason: a project nobody copied is the first of its line.
  String get effectiveLineageId => lineageId ?? projectId;

  /// The center of the project's area, or null when it has none — where a
  /// default time zone is read from (task 11.331). The plain midpoint of the
  /// bounding box; no project area crosses the antimeridian today, and one
  /// that did would be offered a zone the creator can see and change.
  ({double latitude, double longitude})? get areaCenter {
    final minLat = bboxMinLat, maxLat = bboxMaxLat;
    final minLon = bboxMinLon, maxLon = bboxMaxLon;
    if (minLat == null || maxLat == null || minLon == null || maxLon == null) {
      return null;
    }
    return (latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2);
  }

  factory Project.fromRow(Map<String, Object?> row) => Project(
    projectId: row['project_id'] as String,
    projectName: row['project_name'] as String,
    description: row['description'] as String?,
    notes: row['notes'] as String?,
    ownerUserId: row['owner_user_id'] as String,
    creationDate: DbCodec.decodeUtc(row['creation_date']),
    bboxMinLat: row['bbox_min_lat'] as double?,
    bboxMinLon: row['bbox_min_lon'] as double?,
    bboxMaxLat: row['bbox_max_lat'] as double?,
    bboxMaxLon: row['bbox_max_lon'] as double?,
    datum: row['datum'] as String? ?? 'WGS84',
    coordinateFormat: CoordinateFormat.fromDb(
      row['coordinate_format'] as String? ?? 'dd',
    ),
    triangulationWindowMinutes:
        (row['triangulation_window_minutes'] as int?) ?? 15,
    lineageId: row['lineage_id'] as String?,
    copiedAt: DbCodec.decodeUtcOrNull(row['copied_at']),
    timeZone: row['time_zone'] as String?,
    sync: SyncMeta.fromRow(row),
  );

  Map<String, Object?> toColumns() => {
    'project_id': projectId,
    'project_name': projectName,
    'description': description,
    'notes': notes,
    'owner_user_id': ownerUserId,
    'creation_date': DbCodec.encodeUtc(creationDate),
    'bbox_min_lat': bboxMinLat,
    'bbox_min_lon': bboxMinLon,
    'bbox_max_lat': bboxMaxLat,
    'bbox_max_lon': bboxMaxLon,
    'datum': datum,
    'coordinate_format': coordinateFormat.db,
    'triangulation_window_minutes': triangulationWindowMinutes,
    'lineage_id': lineageId,
    'copied_at': DbCodec.encodeUtcOrNull(copiedAt),
    'time_zone': timeZone,
    ...sync.toColumns(),
  };
}

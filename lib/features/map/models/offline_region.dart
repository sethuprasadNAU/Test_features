import 'package:latlong2/latlong.dart';

/// What kind of data an [OfflineRegion] tracks coverage for.
enum OfflineRegionKind { tiles, dem }

/// Download/coverage state of an [OfflineRegion].
enum OfflineRegionStatus { downloading, complete, partial, failed }

/// A user-defined offline-download region and its coverage state.
///
/// This is device-local cache metadata (what has been downloaded to THIS
/// device), deliberately kept OUT of the synced SQLite model and stored in a
/// JSON manifest instead. LatLng vertices serialize as `{lat,lng}`; timestamps
/// as ISO-8601 strings.
class OfflineRegion {
  const OfflineRegion({
    required this.id,
    required this.kind,
    required this.polygon,
    required this.tileTotal,
    required this.tileCompleted,
    required this.status,
    required this.sizeBytes,
    required this.createdAt,
    required this.updatedAt,
    this.name,
    this.sourceId,
    this.minZoom,
    this.maxZoom,
    this.cellSizeMeters,
    this.sharedBytes = 0,
    this.sharedWithIds = const [],
  });

  final String id;
  final OfflineRegionKind kind;

  /// What the person called this area, or null for an area downloaded before
  /// task 11.230 asked for a name. Read [displayName] for a label.
  final String? name;
  final List<LatLng> polygon;

  /// Tiles only: the tile source id and zoom range covered.
  final String? sourceId;
  final int? minZoom;
  final int? maxZoom;

  /// DEM only: the fixed cell size the DEM tiles were generated at.
  final double? cellSizeMeters;

  /// Total units of coverage (map tiles, or DEM tiles) the region should have.
  final int tileTotal;

  /// Units actually present on disk.
  final int tileCompleted;

  final OfflineRegionStatus status;

  /// Bytes on disk of every tile this area covers — its own footprint,
  /// counting a tile shared with another area in full.
  final int sizeBytes;

  /// Of [sizeBytes], the bytes that at least one *other* area also covers.
  /// Tiles live in one shared tree with no record of which area wanted them,
  /// so two overlapping areas hold the same file once and each count it —
  /// task 11.230. Deleting this area leaves those bytes on the device, so
  /// [exclusiveBytes] is what a delete actually frees. Written by
  /// `OfflineRegionStore.reconcileWithDisk`; 0 for a manifest written before
  /// it was recorded.
  final int sharedBytes;

  /// Ids of the other areas that cover at least one tile this area holds —
  /// the areas [sharedBytes] is shared with. Same provenance as
  /// [sharedBytes].
  final List<String> sharedWithIds;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// What deleting this area would free: its footprint less what another
  /// area still covers.
  int get exclusiveBytes => sizeBytes - sharedBytes;

  /// [name], or the kind's generic label when nobody has named it.
  String get displayName =>
      name ?? (kind == OfflineRegionKind.dem ? 'Elevation area' : 'Tile area');

  OfflineRegion copyWith({
    String? id,
    OfflineRegionKind? kind,
    String? name,
    List<LatLng>? polygon,
    String? sourceId,
    int? minZoom,
    int? maxZoom,
    double? cellSizeMeters,
    int? tileTotal,
    int? tileCompleted,
    OfflineRegionStatus? status,
    int? sizeBytes,
    int? sharedBytes,
    List<String>? sharedWithIds,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      OfflineRegion(
        id: id ?? this.id,
        kind: kind ?? this.kind,
        name: name ?? this.name,
        polygon: polygon ?? this.polygon,
        sourceId: sourceId ?? this.sourceId,
        minZoom: minZoom ?? this.minZoom,
        maxZoom: maxZoom ?? this.maxZoom,
        cellSizeMeters: cellSizeMeters ?? this.cellSizeMeters,
        tileTotal: tileTotal ?? this.tileTotal,
        tileCompleted: tileCompleted ?? this.tileCompleted,
        status: status ?? this.status,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        sharedBytes: sharedBytes ?? this.sharedBytes,
        sharedWithIds: sharedWithIds ?? this.sharedWithIds,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        if (name != null) 'name': name,
        'polygon': [
          for (final p in polygon) {'lat': p.latitude, 'lng': p.longitude},
        ],
        if (sourceId != null) 'sourceId': sourceId,
        if (minZoom != null) 'minZoom': minZoom,
        if (maxZoom != null) 'maxZoom': maxZoom,
        if (cellSizeMeters != null) 'cellSizeMeters': cellSizeMeters,
        'tileTotal': tileTotal,
        'tileCompleted': tileCompleted,
        'status': status.name,
        'sizeBytes': sizeBytes,
        if (sharedBytes != 0) 'sharedBytes': sharedBytes,
        if (sharedWithIds.isNotEmpty) 'sharedWithIds': sharedWithIds,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory OfflineRegion.fromJson(Map<String, Object?> json) => OfflineRegion(
        id: json['id'] as String,
        kind: OfflineRegionKind.values.byName(json['kind'] as String),
        name: json['name'] as String?,
        polygon: [
          for (final p in (json['polygon'] as List<Object?>? ?? const []))
            LatLng(
              ((p as Map<String, Object?>)['lat'] as num).toDouble(),
              (p['lng'] as num).toDouble(),
            ),
        ],
        sourceId: json['sourceId'] as String?,
        minZoom: (json['minZoom'] as num?)?.toInt(),
        maxZoom: (json['maxZoom'] as num?)?.toInt(),
        cellSizeMeters: (json['cellSizeMeters'] as num?)?.toDouble(),
        tileTotal: (json['tileTotal'] as num?)?.toInt() ?? 0,
        tileCompleted: (json['tileCompleted'] as num?)?.toInt() ?? 0,
        status: OfflineRegionStatus.values.byName(json['status'] as String),
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        sharedBytes: (json['sharedBytes'] as num?)?.toInt() ?? 0,
        sharedWithIds: [
          for (final id in (json['sharedWithIds'] as List<Object?>? ?? const []))
            id as String,
        ],
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}

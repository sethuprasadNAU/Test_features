/// Where a map should open when nobody has told it where the person is.
///
/// **Task 11.103.** Every map in this app used to end its fallback chain with
/// `LatLng(0, 0)`. That is a *valid* coordinate — a spot in the Gulf of Guinea
/// — so nothing threw, nothing logged, and nothing warned. "I do not know
/// where you are" was rendered as "you are here", which is the
/// null-that-means-two-things class in map form.
///
/// The fix is not a special case for `0, 0`. It is this type: a target either
/// **names its source** or says, in the type system, that nothing was
/// supplied. A caller cannot pass [MapCameraTarget.center] to a map without
/// first handling the null, and the only thing it is allowed to substitute is
/// [MapCameraTarget.worldViewCenter] at [MapCameraTarget.worldViewZoom] —
/// a framing of the whole planet, which claims nothing about where anybody is.
library;

import 'package:latlong2/latlong.dart' as ll;

/// A point with a time, which is all [chooseMapCameraTarget] needs to know
/// about a recording. Deliberately not any of the app's row types: the map,
/// the offline-region screen and the extent picker each hold different ones,
/// and the chain is the same for all of them.
class MapPointInTime {
  const MapPointInTime(this.latitude, this.longitude, this.timestampUtc);

  final double latitude;
  final double longitude;
  final DateTime timestampUtc;
}

/// A geographic rectangle. Only ever built from something somebody supplied —
/// a project's stored extent, or real recorded points.
class GeoExtent {
  const GeoExtent({
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
  });

  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  /// The project's stored extent, or null if it has none.
  ///
  /// **All four corners or nothing.** A half-populated bbox is not an extent,
  /// and treating three nulls and one number as "we have a corner" is how a
  /// coordinate nobody supplied gets back in.
  static GeoExtent? fromProjectBbox({
    double? minLat,
    double? minLon,
    double? maxLat,
    double? maxLon,
  }) {
    if (minLat == null || minLon == null || maxLat == null || maxLon == null) {
      return null;
    }
    if (!_allFinite([minLat, minLon, maxLat, maxLon])) return null;
    return GeoExtent(
      minLat: minLat < maxLat ? minLat : maxLat,
      minLon: minLon < maxLon ? minLon : maxLon,
      maxLat: minLat < maxLat ? maxLat : minLat,
      maxLon: minLon < maxLon ? maxLon : minLon,
    );
  }

  /// The rectangle containing every point in [points], or null if there are
  /// none (or none with usable coordinates).
  static GeoExtent? around(Iterable<MapPointInTime> points) {
    double? minLat, minLon, maxLat, maxLon;
    for (final p in points) {
      if (!_allFinite([p.latitude, p.longitude])) continue;
      if (p.latitude.abs() > 90 || p.longitude.abs() > 180) continue;
      minLat = minLat == null || p.latitude < minLat ? p.latitude : minLat;
      maxLat = maxLat == null || p.latitude > maxLat ? p.latitude : maxLat;
      minLon = minLon == null || p.longitude < minLon ? p.longitude : minLon;
      maxLon = maxLon == null || p.longitude > maxLon ? p.longitude : maxLon;
    }
    if (minLat == null) return null;
    return GeoExtent(
      minLat: minLat,
      minLon: minLon!,
      maxLat: maxLat!,
      maxLon: maxLon!,
    );
  }

  ll.LatLng get center =>
      ll.LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);

  /// True when the extent has no meaningful width or height — one recording,
  /// or several from the same spot. Fitting a camera to a zero-area box gives
  /// flutter_map's maximum zoom, which is not what anybody wants to see.
  bool get isEffectivelyAPoint =>
      (maxLat - minLat) < 1e-6 && (maxLon - minLon) < 1e-6;

  static bool _allFinite(List<double> values) => values.every((v) => v.isFinite);

  @override
  String toString() =>
      'GeoExtent($minLat, $minLon → $maxLat, $maxLon)';
}

/// Which of Michael's four steps supplied the view. Reported so a screen can
/// say something true about why it is looking where it is looking, and so a
/// test can assert the step rather than the number it happened to produce.
enum MapCameraSource {
  /// This device's own position fix.
  devicePosition,

  /// The extent of the most recently recorded data in the active project.
  recentRecordedData,

  /// The project's stored map extent.
  projectExtent,

  /// **Nobody supplied anything.** A new project's first minute, on a device
  /// with no fix. There is no honest coordinate for this case, so this target
  /// carries none.
  nothingSupplied,
}

/// The answer to "where should this map open".
class MapCameraTarget {
  const MapCameraTarget._({
    required this.source,
    required this.center,
    required this.extent,
    required this.zoom,
  });

  final MapCameraSource source;

  /// **Null exactly when [source] is [MapCameraSource.nothingSupplied].**
  ///
  /// The nullability is the enforcement: a caller has to write down what it
  /// does with "I do not know", and the only sanctioned answer is
  /// [worldViewCenter] at [worldViewZoom].
  final ll.LatLng? center;

  /// Set when the target came from a rectangle worth fitting the camera to
  /// (a project extent, or several recordings). Null for a single point and
  /// for a device fix, where a fixed zoom reads better than a fit.
  final GeoExtent? extent;

  /// The zoom to use when [extent] is null.
  final double zoom;

  bool get isSupplied => source != MapCameraSource.nothingSupplied;

  /// The centre of a whole-planet framing.
  ///
  /// **This is not a location and must never be presented as one.** It exists
  /// so that a map with nothing to show can still be drawn, panned and tapped
  /// — which matters, because tapping the map is how somebody places a first
  /// pin when there is no fix. Latitude 20° puts the populated landmasses in
  /// frame rather than the Southern Ocean; at [worldViewZoom] the entire world
  /// is visible, so the centre asserts nothing about anybody's whereabouts.
  static const ll.LatLng worldViewCenter = ll.LatLng(20, 0);

  /// Whole-planet zoom. Kept at the app's `minZoom` so the view reads
  /// immediately as "everywhere", not as a place.
  static const double worldViewZoom = 2;

  /// The sentence a person sees when nothing was supplied. **Ends with
  /// something to try** — the standing rule from task 11.104.
  static const String nothingSuppliedMessage =
      'TriTrack does not know where you are, and this project has no '
      'recordings or extent yet. Pan to your study area, or set the project '
      'extent under More › Project.';

  @override
  String toString() =>
      'MapCameraTarget(${source.name}, center: $center, extent: $extent, '
      'zoom: $zoom)';
}

/// How far back from the newest recording counts as "the most recently
/// recorded data".
///
/// A calendar day would have been the obvious rule and is the wrong one: a
/// field session that runs from dusk into the small hours straddles a
/// midnight, and a UTC midnight lands in the middle of the working evening
/// across most of the Americas. A window measured back from the newest point
/// has no boundary to land on.
const Duration recentRecordingWindow = Duration(hours: 24);

/// Zoom for a target that is a single point rather than a rectangle.
const double _pointZoom = 14;

/// **Michael's fallback order, 2026-08-31, with the two open steps decided.**
///
/// 1. [devicePosition], if this device has one.
/// 2. Otherwise the extent of the **most recently recorded data** in the
///    active project — everything recorded within [recentRecordingWindow] of
///    the newest recording, which is "where you were working last".
/// 3. Otherwise the project's stored [projectExtent].
/// 4. Otherwise [MapCameraSource.nothingSupplied]. **No coordinate is
///    invented here.**
///
/// **Decision — a remembered last-viewed map position.** It does not go into
/// this chain, because the app does not persist one: nothing under
/// `lib/core/providers/` stores a map camera (checked 2026-09-01 —
/// `map_settings_provider` stores the chosen basemap, `active_selection`
/// stores project and user ids, and that is the whole of it). Adding
/// persistence would be a new feature arriving inside a defect fix, so this
/// task does not add it. If it is ever added, it belongs **between steps 2 and
/// 3**: a view somebody deliberately left is better evidence of where they are
/// working than a project extent drawn once at setup, but it is worse evidence
/// than data recorded in the last day.
MapCameraTarget chooseMapCameraTarget({
  required ll.LatLng? devicePosition,
  Iterable<MapPointInTime> recorded = const [],
  GeoExtent? projectExtent,
  double devicePositionZoom = _pointZoom,
}) {
  if (devicePosition != null) {
    return MapCameraTarget._(
      source: MapCameraSource.devicePosition,
      center: devicePosition,
      extent: null,
      zoom: devicePositionZoom,
    );
  }

  final recentExtent = GeoExtent.around(_mostRecent(recorded));
  if (recentExtent != null) {
    return MapCameraTarget._(
      source: MapCameraSource.recentRecordedData,
      center: recentExtent.center,
      extent: recentExtent.isEffectivelyAPoint ? null : recentExtent,
      zoom: _pointZoom,
    );
  }

  if (projectExtent != null) {
    return MapCameraTarget._(
      source: MapCameraSource.projectExtent,
      center: projectExtent.center,
      extent: projectExtent.isEffectivelyAPoint ? null : projectExtent,
      zoom: _pointZoom,
    );
  }

  return const MapCameraTarget._(
    source: MapCameraSource.nothingSupplied,
    center: null,
    extent: null,
    zoom: MapCameraTarget.worldViewZoom,
  );
}

/// Everything recorded within [recentRecordingWindow] of the newest recording.
Iterable<MapPointInTime> _mostRecent(Iterable<MapPointInTime> points) {
  DateTime? newest;
  for (final p in points) {
    if (newest == null || p.timestampUtc.isAfter(newest)) newest = p.timestampUtc;
  }
  if (newest == null) return const [];
  final cutoff = newest.subtract(recentRecordingWindow);
  return points.where((p) => !p.timestampUtc.isBefore(cutoff));
}

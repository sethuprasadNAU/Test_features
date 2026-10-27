import 'dart:math' as math;

import '../../localization/coordinate_projection.dart';
import '../../localization/localization_geographic.dart';
import '../../localization/localization_types.dart';
import '../models/deployment.dart';
import '../models/estimated_position.dart';
import '../models/individual.dart';
import '../models/observation.dart';
import '../models/tag.dart';
import '../models/user.dart';
import '../repositories/deployment_repository.dart';
import 'csv_writer.dart';

/// CSV export of **saved position estimates** — task 11.323 item 3. Before
/// this they left the device only inside a full backup, so a methods section
/// had the bearings and the truth points and not the estimates made from them.
///
/// One row per saved estimate (a deleted one is left out, as the screens
/// leave it out).
///
/// ## What is stored and what is recomputed — the columns say which
///
/// A saved estimate stores its point, its ellipse and the ids of the bearings
/// it used. **It does not store κ or the cautions**, so those two columns are
/// **recomputed** here from the same bearings with this build's solver, and
/// named `kappa_recomputed` and `cautions_recomputed` so nobody reads them as
/// what the screen showed when the estimate was saved. They agree with it when
/// every bearing is still on this device unchanged and the solver has not
/// changed since; `bearings_on_device` and `recomputed_offset_m` (how far the
/// recomputed point is from the saved one) say whether that is so for each
/// row. Storing κ and the cautions with the estimate would need columns the
/// table does not have.
///
/// ## The ellipse, or none
///
/// The three ellipse columns and `ellipse_confidence` are **all empty** for an
/// estimate with no ellipse — two bearings cross exactly, so there is no
/// spread to measure (schema v19). Otherwise the axes are in meters, the
/// orientation is the major axis as a compass bearing (degrees clockwise from
/// true north), and the confidence is the coverage the axes were scaled to:
/// 0.95, the only value the app has ever used.
///
/// ## The animal
///
/// Read with `DeploymentRepository.animalForObservationIn` at the moment the
/// estimate was saved — the one derivation of *which animal wore this collar
/// then* — so it agrees with the Log. Two names, joined with " / ", mean the
/// collar's deployments overlap at that moment; empty means it was on nobody.
abstract final class PositionEstimateCsv {
  static const _header = [
    'position_id',
    // Who saved it — the row's last writer, which for an estimate is the
    // person who saved it, since an estimate is never edited, only deleted.
    // The raw id when this device holds no `Users` row for them.
    'saved_by',
    'timestamp_local',
    'timestamp_utc',
    'timezone_offset',
    'tag_id',
    // The collar as it is called now; `tags.csv` joins on `tag_id`.
    'tag_name',
    'tag_frequency_mhz',
    'animal',
    'individual_id',
    'latitude',
    'longitude',
    'ellipse_semi_major_m',
    'ellipse_semi_minor_m',
    'ellipse_orientation_deg',
    'ellipse_confidence',
    'bearing_count',
    // Semicolon-separated `observation_id`s, to join on `observations.csv`.
    'bearing_ids',
    'bearings_on_device',
    // Minutes between the earliest and latest of those bearings on this
    // device — the fact the screen's time-span caution is judged from.
    'time_span_minutes',
    'kappa_recomputed',
    'cautions_recomputed',
    'recomputed_offset_m',
    'method',
    'notes',
  ];

  /// The coverage every saved ellipse is scaled to (`LenthConfig`'s default,
  /// which the app never overrides).
  static const _ellipseConfidence = 0.95;

  static String export(
    List<EstimatedPosition> estimates, {
    required Map<String, Tag> tagsById,
    required Map<String, User> usersById,
    required Map<String, Individual> individualsById,
    required List<Deployment> deployments,
    required Map<String, Observation> observationsById,
  }) {
    final rows = <List<dynamic>>[_header];
    for (final e in estimates) {
      if (e.sync.isDeleted) continue;
      final tag = tagsById[e.tagId];
      final saverId = e.sync.lastModifiedBy;
      final saver = saverId == null ? null : usersById[saverId];
      final attribution = DeploymentRepository.animalForObservationIn(
        deployments,
        tagId: e.tagId,
        at: e.timestampUtc,
      );
      final bearings = [
        for (final id in e.observationIdsUsed)
          ?observationsById[id],
      ].where((o) => !o.sync.isDeleted && o.trueNorthBearing != null).toList();
      final recomputed = _recompute(e, bearings);
      rows.add([
        e.positionId,
        saverId == null
            ? null
            : (saver == null ? saverId : '${saver.firstName} ${saver.lastName}'),
        e.timestampLocal.toIso8601String(),
        e.timestampUtc.toIso8601String(),
        e.timezoneOffset,
        e.tagId,
        tag?.tagName,
        tag?.frequencyMhz,
        [
          for (final id in attribution.candidates)
            individualsById[id]?.name ?? id,
        ].join(' / '),
        attribution.candidates.join(' / '),
        e.latitude,
        e.longitude,
        e.hasEllipse ? e.semiMajorAxis : null,
        e.hasEllipse ? e.semiMinorAxis : null,
        e.hasEllipse ? e.rotationAngle : null,
        e.hasEllipse ? _ellipseConfidence : null,
        e.observationIdsUsed.length,
        e.observationIdsUsed.join(';'),
        bearings.length,
        _spanMinutes(bearings),
        recomputed.kappa,
        recomputed.cautions,
        recomputed.offsetMeters,
        e.method.db,
        e.notes,
      ]);
    }
    return SpreadsheetSafeCsv.encode(rows);
  }

  static int? _spanMinutes(List<Observation> bearings) {
    if (bearings.isEmpty) return null;
    final times = bearings.map((o) => o.timestampUtc).toList()..sort();
    return times.last.difference(times.first).inMinutes;
  }

  /// κ, the caution codes and the offset from the saved point, from the
  /// bearings still on this device. κ is empty when it is not a finite
  /// number — two bearings, whose spread cannot be measured.
  static ({String? kappa, String cautions, double? offsetMeters}) _recompute(
    EstimatedPosition e,
    List<Observation> bearings,
  ) {
    final result = LenthGeographic.solve([
      for (final o in bearings)
        GeographicObservation(
          latitude: o.latitude,
          longitude: o.longitude,
          trueNorthBearingDeg: o.trueNorthBearing!,
          id: o.observationId,
          positionAccuracyM: o.positionAccuracyM,
        ),
    ]);
    final kappa = result.planar.kappa;
    double? offset;
    if (result.hasEstimate) {
      final projection = LocalTangentProjection(result.projectionOrigin);
      final saved = projection.forward(GeoPoint(e.latitude, e.longitude));
      final now = projection.forward(
        GeoPoint(result.latitude!, result.longitude!),
      );
      offset = math.sqrt(
        math.pow(saved.east - now.east, 2) +
            math.pow(saved.north - now.north, 2),
      );
    }
    return (
      kappa: kappa == null || !kappa.isFinite ? null : kappa.toStringAsFixed(3),
      cautions: [
        for (final w in result.warnings) cautionCode(w),
      ].join(';'),
      offsetMeters: offset == null ? null : (offset * 10).round() / 10,
    );
  }

  /// A caution as a stable code rather than the screen's sentence, which is
  /// reworded from time to time — `near_parallel`, `high_gdop` and so on.
  static String cautionCode(GeometryWarning warning) => warning.name
      .replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
}

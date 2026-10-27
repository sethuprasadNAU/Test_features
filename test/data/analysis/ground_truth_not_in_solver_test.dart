import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/analysis/analysis_eligibility.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/actual_tag_location.dart';
import 'package:tritrack/data/repositories/actual_tag_location_repository.dart';
import 'package:tritrack/data/repositories/observation_exclusion_repository.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack/localization/localization_geographic.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.33's one invariant, proved rather than trusted: a ground-truth
/// point never enters the position-estimate solver.**
///
/// A truth point is where the animal or the collar actually turned out to be —
/// the yardstick the estimates are measured against. If it could reach the
/// solver, the solver would be marking its own homework: the estimate would be
/// dragged toward the answer it is supposed to be judged against, and the
/// closer the app looked, the less that closeness would mean.
///
/// **Why this is a test and not a comment.** The protection is structural: a
/// truth point lives in `Actual_Tag_Locations`, which no query the solver runs
/// ever reads, so nothing has to *remember* to exclude it. That is a stronger
/// guarantee than an exemption — this project's recurring finding is that
/// wherever a control deliberately ignores a row type, that exemption is where
/// the next problem turns up. But "the tables are separate" is only true while
/// somebody keeps it true. This test fails the moment a truth point becomes a
/// kind of observation, which is exactly the refactor that would look tidy and
/// quietly corrupt every accuracy figure the feature exists to produce.
void main() {
  late AppDatabase database;
  late ObservationRepository observations;
  late ActualTagLocationRepository truthPoints;
  late ObservationExclusionRepository marks;

  // Eight observers on a ring around a source near (35.20, -111.60), each
  // bearing back toward it with a couple of degrees of real compass scatter.
  // Same geometry as `analysis_eligibility_test.dart`, and for the same
  // reason: a perfectly consistent set produces no uncertainty ellipse at all,
  // so it could not show a change in one.
  const ring = <(String, double, double, double)>[
    ('o0', 35.240000, -111.600000, 178.4416),
    ('o1', 35.228284, -111.564645, 232.2660),
    ('o2', 35.200000, -111.550000, 269.9701),
    ('o3', 35.171716, -111.564645, 308.5962),
    ('o4', 35.160000, -111.600000, 1.2140),
    ('o5', 35.171716, -111.635355, 52.6396),
    ('o6', 35.200000, -111.650000, 88.3126),
    ('o7', 35.228284, -111.635355, 130.0400),
  ];

  /// Everything the position-estimate screen feeds its solver, read back out
  /// of the database the same way it reads it: every observation for the tag,
  /// minus the superseded and excluded ones.
  Future<GeographicLocalizationResult> solveFromDatabase() async {
    final all = await observations.findByProjectAndTag('project-1', 'tag-1');
    final live = await marks.activeByObservation('project-1');
    final included = AnalysisEligibility.eligible(all, live)
        .where((o) =>
            o.observationType == ObservationType.directional &&
            o.trueNorthBearing != null)
        .toList();
    return LenthGeographic.solve([
      for (final o in included)
        GeographicObservation(
          latitude: o.latitude,
          longitude: o.longitude,
          trueNorthBearingDeg: o.trueNorthBearing!,
          id: o.observationId,
          positionAccuracyM: o.positionAccuracyM,
        ),
    ]);
  }

  setUp(() async {
    database = await AppDatabase.openInMemory();
    observations = ObservationRepository(database.raw);
    truthPoints = ActualTagLocationRepository(database.raw);
    marks = ObservationExclusionRepository(database.raw);

    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject());
    await TagRepository(database.raw).insert(sampleTag());

    for (final (id, lat, lon, bearing) in ring) {
      await observations.insert(
        sampleObservation(id: id, sessionId: null, latitude: lat, longitude: lon)
            .copyWith(trueNorthBearing: bearing),
      );
    }
  });

  tearDown(() => database.close());

  test(
    'the estimate is identical with and without a truth point sitting beside '
    'the bearings it will be judged against',
    () async {
      final without = await solveFromDatabase();
      expect(without.hasEstimate, isTrue,
          reason: 'the fixture geometry must actually solve, or this test '
              'would pass by comparing two failures');
      expect(without.ellipseSemiMajorMeters, isNotNull,
          reason: 'and it must report an uncertainty ellipse, which is the '
              'number a stray extra point would move most');

      // A truth point for the same tag, in the same project, a few metres from
      // where the bearings put the animal — the case where a leak would be
      // hardest to notice, because the estimate would still look plausible.
      await truthPoints.insert(
        ActualTagLocation(
          locationId: 'truth-1',
          projectId: 'project-1',
          tagId: 'tag-1',
          timestampLocal: DateTime(2026, 7, 16, 11, 30),
          timestampUtc: DateTime.utc(2026, 7, 16, 18, 30),
          timezoneOffset: '-07:00',
          latitude: 35.2004,
          longitude: -111.6008,
          uncertaintyRadius: 4,
          notes: 'collar in the open, animal visible 3 m away',
          foundKind: GroundTruthKind.animalAndCollar,
          tagVersionId: null,
          sync: sampleSync(),
        ),
      );

      // It is stored — otherwise "the estimate did not move" would be proving
      // nothing at all.
      expect(
        (await truthPoints.findByProject('project-1')).single.locationId,
        'truth-1',
      );

      final with_ = await solveFromDatabase();
      expect(with_.latitude, without.latitude);
      expect(with_.longitude, without.longitude);
      expect(with_.ellipseSemiMajorMeters, without.ellipseSemiMajorMeters);
      expect(with_.ellipseSemiMinorMeters, without.ellipseSemiMinorMeters);
      expect(with_.ellipseRotationDegrees, without.ellipseRotationDegrees);

      // **Negative control.** Everything above would also hold if this test
      // were simply unable to see a ninth point — comparing two identical
      // failures and calling it a pass. So add one real extra bearing from the
      // truth point's position and prove the comparison moves when a row does
      // reach the solver.
      await observations.insert(
        sampleObservation(
          id: 'o8',
          sessionId: null,
          latitude: 35.2004,
          longitude: -111.6008,
        ).copyWith(trueNorthBearing: 45),
      );
      final leaked = await solveFromDatabase();
      expect(leaked.latitude, isNot(without.latitude));
    },
  );

  test(
    'saving a truth point writes no Observations row, so no solver query can '
    'reach it',
    () async {
      await truthPoints.insert(
        ActualTagLocation(
          locationId: 'truth-2',
          projectId: 'project-1',
          tagId: 'tag-1',
          timestampLocal: DateTime(2026, 7, 16, 11, 30),
          timestampUtc: DateTime.utc(2026, 7, 16, 18, 30),
          timezoneOffset: '-07:00',
          latitude: 35.2004,
          longitude: -111.6008,
          uncertaintyRadius: 4,
          foundKind: GroundTruthKind.collarOnly,
          sync: sampleSync(),
        ),
      );

      final rows = await database.raw.query(Tables.observations);
      expect(rows.length, ring.length);
      expect(
        rows.map((r) => r['observation_id']),
        isNot(contains('truth-2')),
      );
    },
  );

  test(
    'the record screen has no way to write a truth point as an observation',
    () {
      // `observationType` is what the Record screen maps its selector through
      // on the way to an `Observations` row. Null is the structural half of
      // this task's invariant: there is no observation type a truth point
      // could be saved as, so the screen has to take the other branch.
      expect(RecordType.groundTruth.observationType, isNull);
    },
  );
}

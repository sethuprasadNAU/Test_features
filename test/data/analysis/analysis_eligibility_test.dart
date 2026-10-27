import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/analysis/analysis_eligibility.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/observation_exclusion.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/localization/localization_geographic.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.7's central claim, proved through the solver rather than through
/// the filter.**
///
/// The requirement is not "the filter removes the right ids" — that is a
/// restatement of the code. It is that the *position estimate a biologist
/// reads* moves when a correction is made and stays put when nothing relevant
/// changed, and above all that a corrected bearing and the bearing it corrects
/// are never both counted. Lenth's maximum-likelihood estimator treats every
/// bearing as an independent line of evidence, so counting one twice reports a
/// position around a confidence ellipse tighter than the data supports — a
/// wrong answer wearing the costume of a better one.
///
/// Every test here therefore solves and compares estimates.
void main() {
  // Eight observers on a ring around a source near (35.20, -111.60), each with
  // a bearing back toward it plus a couple of degrees of the scatter a real
  // compass produces.
  //
  // **A realistic set matters.** Given three or four perfectly consistent
  // bearings the solver reports no uncertainty ellipse at all — there are no
  // residuals to estimate a spread from — so a test built on that geometry
  // could not see the effect this task exists to prevent. Discovered by
  // measurement while writing these tests, not assumed.
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

  Observation obs(
    String id, {
    required double lat,
    required double lon,
    required double bearing,
    String userId = 'user-1',
  }) => sampleObservation(
    id: id,
    userId: userId,
    sessionId: null,
    latitude: lat,
    longitude: lon,
  ).copyWith(trueNorthBearing: bearing);

  final clean = [
    for (final (id, lat, lon, bearing) in ring)
      obs(id, lat: lat, lon: lon, bearing: bearing),
  ];

  /// The two-people-one-observation case the plan names: a second member
  /// logged the *same* bearing on the same animal from the same spot. One
  /// event, two rows.
  final duplicate = obs(
    'o0-again',
    lat: ring.first.$2,
    lon: ring.first.$3,
    bearing: ring.first.$4,
    userId: 'user-2',
  );

  /// A mis-read compass: o0's position, eleven degrees off.
  final misread = obs(
    'o0-misread',
    lat: ring.first.$2,
    lon: ring.first.$3,
    bearing: ring.first.$4 + 11,
  );

  ObservationExclusion mark(
    String observationId, {
    required ObservationExclusionKind kind,
    String? replacement,
    String? reason,
    String id = 'mark-1',
  }) => ObservationExclusion(
    exclusionId: id,
    projectId: 'project-1',
    observationId: observationId,
    userId: 'user-2',
    kind: kind,
    supersededByObservationId: replacement,
    reason: reason,
    sync: SyncMeta.initial(
      now: DateTime.utc(2026, 8, 21),
      modifiedBy: 'user-2',
      originDeviceId: 'device-1',
    ),
  );

  GeographicLocalizationResult solve(List<Observation> observations) =>
      LenthGeographic.solve([
        for (final o in observations)
          GeographicObservation(
            latitude: o.latitude,
            longitude: o.longitude,
            trueNorthBearingDeg: o.trueNorthBearing!,
            id: o.observationId,
            positionAccuracyM: o.positionAccuracyM,
          ),
      ]);

  GeographicLocalizationResult solveEligible(
    List<Observation> observations,
    Map<String, ObservationExclusion> marks,
  ) => solve(AnalysisEligibility.eligible(observations, marks));

  group('the double-count hazard', () {
    test(
      'counting a record and the record that supersedes it reports a tighter '
      'ellipse than the evidence supports',
      () {
        // Eight real bearings; the ninth row is one of them logged a second
        // time by a teammate. Nothing new was measured.
        final both = [...clean, duplicate];
        final honest = solve(clean);
        final doubleCounted = solve(both);
        final marked = solveEligible(both, {
          'o0-again': mark(
            'o0-again',
            kind: ObservationExclusionKind.superseded,
            replacement: 'o0',
          ),
        });

        expect(honest.hasEstimate, isTrue);
        expect(doubleCounted.hasEstimate, isTrue);

        // The failure, measured: the duplicated evidence shrinks the reported
        // uncertainty. This is the number that would mislead somebody.
        expect(
          doubleCounted.ellipseSemiMajorMeters!,
          lessThan(honest.ellipseSemiMajorMeters!),
        );

        // And the fix: with the mark in place the solver reports the honest
        // ellipse again, to the last digit.
        expect(
          marked.ellipseSemiMajorMeters,
          honest.ellipseSemiMajorMeters,
        );
        expect(marked.latitude, honest.latitude);
        expect(marked.longitude, honest.longitude);
      },
    );
  });

  group('superseding', () {
    final withMisread = [...clean, misread];
    final superseded = {
      'o0-misread': mark(
        'o0-misread',
        kind: ObservationExclusionKind.superseded,
        replacement: 'o0',
      ),
    };

    test('counts the superseding record and not the one it replaces', () {
      final result = solveEligible(withMisread, superseded);
      final byHand = solve(clean);

      expect(result.hasEstimate, isTrue);
      // Identical to solving the corrected set by hand: the mis-read bearing
      // contributes nothing at all, not merely less.
      expect(result.latitude, byHand.latitude);
      expect(result.longitude, byHand.longitude);
      expect(result.ellipseSemiMajorMeters, byHand.ellipseSemiMajorMeters);
    });

    test('and the estimate moves — the correction is not a no-op dressed up '
        'as one', () {
      final corrected = solveEligible(withMisread, superseded);
      final uncorrected = solve(withMisread);

      expect(corrected.hasEstimate, isTrue);
      expect(uncorrected.hasEstimate, isTrue);
      expect(corrected.latitude, isNot(uncorrected.latitude));
      expect(
        corrected.ellipseSemiMajorMeters,
        isNot(uncorrected.ellipseSemiMajorMeters),
      );
    });

    test('a mark on an observation this tag never had leaves the estimate '
        'exactly where it was', () {
      final before = solve(clean);
      final after = solveEligible(clean, {
        'some-other-tags-row': mark(
          'some-other-tags-row',
          kind: ObservationExclusionKind.superseded,
          replacement: 'o0',
        ),
      });

      expect(after.latitude, before.latitude);
      expect(after.longitude, before.longitude);
      expect(after.ellipseSemiMajorMeters, before.ellipseSemiMajorMeters);
    });

    test('the replacement going away does not quietly re-admit the record it '
        'replaced', () {
      // The conservative direction, and deliberate: whoever said "this bearing
      // is wrong" said it about the bearing, not about the replacement.
      // Silently re-admitting it is the direction that over-counts.
      final withoutTheReplacement = [
        for (final o in clean)
          if (o.observationId != 'o0') o,
        misread,
      ];
      final result = solveEligible(withoutTheReplacement, superseded);
      final asIfReadmitted = solve(withoutTheReplacement);

      expect(result.hasEstimate, isTrue);
      expect(result.latitude, isNot(asIfReadmitted.latitude));
    });
  });

  group('excluding', () {
    final withMisread = [...clean, misread];
    final excluded = {
      'o0-misread': mark('o0-misread', kind: ObservationExclusionKind.excluded),
    };

    test('moves the estimate off the excluded bearing', () {
      final withIt = solve(withMisread);
      final withoutIt = solveEligible(withMisread, excluded);

      expect(withIt.hasEstimate, isTrue);
      expect(withoutIt.hasEstimate, isTrue);
      expect(withoutIt.latitude, isNot(withIt.latitude));
      expect(withoutIt.latitude, solve(clean).latitude);
    });

    test('and withdrawing the exclusion puts the estimate back exactly', () {
      // Withdrawing tombstones the mark, after which
      // `activeByObservation` returns nothing for it — which is what the empty
      // map stands in for here. The repository test proves the tombstone half.
      final before = solve(withMisread);
      final after = solveEligible(withMisread, const {});

      expect(after.latitude, before.latitude);
      expect(after.longitude, before.longitude);
      expect(after.ellipseSemiMajorMeters, before.ellipseSemiMajorMeters);
    });
  });

  group('what the row itself says', () {
    test('a superseded observation explains itself in words', () {
      final reason = AnalysisEligibility.withheldReason(misread, {
        'o0-misread': mark(
          'o0-misread',
          kind: ObservationExclusionKind.superseded,
          replacement: 'o0',
        ),
      });
      expect(reason, contains('Superseded'));
      expect(reason, contains('not counted in position estimates'));
    });

    test("an owner's reason is carried through to the row", () {
      final reason = AnalysisEligibility.withheldReason(misread, {
        'o0-misread': mark(
          'o0-misread',
          kind: ObservationExclusionKind.excluded,
          reason: 'bounced off the ridge',
        ),
      });
      expect(reason, contains('Excluded'));
      expect(reason, contains('bounced off the ridge'));
    });

    test('an observation with no mark says nothing', () {
      expect(AnalysisEligibility.withheldReason(clean.first, const {}), isNull);
    });
  });

  // =====================================================================
  // Task 11.193 — the flag that says the signal sounded wrong changes
  // nothing here, and that is an assertion rather than an omission.
  // =====================================================================

  group('a signal somebody heard as irregular', () {
    /// **Withdrawing a bearing is its own act, with a name on it.** The flag
    /// records what a person heard; taking a bearing out of a position
    /// estimate is an `ObservationExclusion` row, made deliberately, by
    /// somebody, with a reason (task 11.7). If the flag quietly did the
    /// second thing, a biologist ticking "sounded irregular" in the field
    /// would silently move every position estimate for that animal and
    /// nothing on any screen would say so — the estimate would simply be
    /// computed from fewer bearings than the map shows.
    ///
    /// Proved through the solver rather than through the filter, like every
    /// other test in this file: the claim is about the answer a person reads,
    /// not about which ids a function returned.
    test('is still counted, and the estimate does not move', () {
      final flagged = [
        for (final o in clean) o.copyWith(signalIrregular: true),
      ];

      expect(
        AnalysisEligibility.eligible(flagged, const {}).length,
        flagged.length,
        reason: 'Every one of these bearings is flagged and every one of them '
            'still counts. This flag is a fact about what was heard; it is '
            'not a decision to withdraw evidence.',
      );

      final asHeard = solve(clean);
      final asFlagged = solveEligible(flagged, const {});
      expect(asFlagged.latitude, asHeard.latitude);
      expect(asFlagged.longitude, asHeard.longitude);
    });

    test('says nothing on the row, because it withholds nothing', () {
      expect(
        AnalysisEligibility.withheldReason(
          clean.first.copyWith(signalIrregular: true),
          const {},
        ),
        isNull,
        reason: 'The Log and Team rows show why an observation is out of '
            'analysis. A flagged bearing is not out of analysis, so there is '
            'nothing to say here — and saying something would teach a reader '
            'that ticking the flag had withdrawn their record.',
      );
    });

    test('and a mark still withdraws one whether it is flagged or not', () {
      // The other direction, so the test above cannot be satisfied by an
      // eligibility filter that has stopped working altogether.
      final flagged = [
        for (final o in clean) o.copyWith(signalIrregular: true),
      ];
      final marks = {
        'o0': mark('o0', kind: ObservationExclusionKind.excluded),
      };
      expect(AnalysisEligibility.eligible(flagged, marks).length,
          flagged.length - 1);
      expect(
        AnalysisEligibility.withheldReason(flagged.first, marks),
        contains('Excluded'),
      );
    });
  });
}

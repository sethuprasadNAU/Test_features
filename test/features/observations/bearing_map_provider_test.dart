import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/compass/heading_smoother.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/features/observations/providers/bearing_map_provider.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 11.315 — the two pieces of *Take on map* that are pure enough to be
/// asked directly: which bearings it draws, and the heading it turns by.
void main() {
  setUp(installFakeSharedPreferences);

  group('earlierBearingsToday — "same tag" and "today", and nothing else', () {
    // Built from the device's own calendar, so the test means the same thing
    // in every time zone it is run in (tasks 11.276 and 11.277 ran the suite
    // under TZ=UTC and found fixtures that did not).
    final now = DateTime(2026, 9, 28, 15, 0);
    final thisMorning = DateTime(2026, 9, 28, 0, 30).toUtc();
    final lastNight = DateTime(2026, 9, 27, 23, 30).toUtc();

    Observation bearing(
      String id, {
      String tagId = 'tag-1',
      DateTime? at,
      ObservationType type = ObservationType.directional,
      bool deleted = false,
      bool hasTrueBearing = true,
    }) {
      final o = sampleObservation(
        id: id,
        tagId: tagId,
        sessionId: null,
        tagVersionId: null,
        timestampUtc: at ?? thisMorning,
      );
      return o.copyWith(
        observationType: type,
        trueNorthBearing: hasTrueBearing ? o.trueNorthBearing : null,
        sync: deleted
            ? o.sync.copyWith(deletedAt: DateTime.utc(2026, 9, 28))
            : o.sync,
      );
    }

    test('keeps a bearing on the same collar taken today', () {
      final kept = earlierBearingsToday(
        [bearing('today')],
        tagId: 'tag-1',
        now: now,
      );
      expect(kept.map((o) => o.observationId), ['today']);
    });

    test('leaves out another collar, yesterday, and everything without a line',
        () {
      final kept = earlierBearingsToday(
        [
          bearing('today'),
          bearing('other-collar', tagId: 'tag-2'),
          bearing('last-night', at: lastNight),
          bearing('a-note', type: ObservationType.note),
          bearing('omni', type: ObservationType.omnidirectional),
          bearing('no-true-bearing', hasTrueBearing: false),
          bearing('deleted', deleted: true),
        ],
        tagId: 'tag-1',
        now: now,
      );
      expect(
        kept.map((o) => o.observationId),
        ['today'],
        reason:
            'Only a directional bearing on this collar, on this device\'s '
            'today, has a line to draw. A bearing half an hour before local '
            'midnight is yesterday\'s, whatever day it is in UTC.',
      );
    });

    test('"today" is read from the UTC instant in this device\'s zone, not '
        'from the recorder\'s wall clock', () {
      // A teammate in another zone: their wall clock says yesterday, but the
      // instant is this morning here. Local-time columns are the recorder's,
      // and this screen's day is this device's.
      final teammate = bearing('teammate').copyWith(
        timestampLocal: DateTime(2026, 9, 27, 22, 0),
      );
      expect(
        earlierBearingsToday([teammate], tagId: 'tag-1', now: now),
        hasLength(1),
      );
    });
  });

  group('the orientation is remembered on this device', () {
    test('starts north up the first time, and keeps a change', () async {
      final first = ProviderContainer();
      addTearDown(first.dispose);
      first.listen(bearingMapOrientationProvider, (_, _) {});
      expect(
        await first.read(bearingMapOrientationProvider.future),
        BearingMapOrientation.northUp,
      );
      await first
          .read(bearingMapOrientationProvider.notifier)
          .set(BearingMapOrientation.facingUp);

      // A new container is a new launch as far as providers are concerned;
      // only the device's preferences carry over.
      final second = ProviderContainer();
      addTearDown(second.dispose);
      second.listen(bearingMapOrientationProvider, (_, _) {});
      expect(
        await second.read(bearingMapOrientationProvider.future),
        BearingMapOrientation.facingUp,
      );
    });

    test('an unknown stored value reads as north up', () {
      expect(
        BearingMapOrientation.parse('sideways'),
        BearingMapOrientation.northUp,
      );
      expect(BearingMapOrientation.parse(null), BearingMapOrientation.northUp);
    });
  });

  group('HeadingSmoother — facing up without the shake', () {
    test('takes the first sample as it is', () {
      final s = HeadingSmoother();
      expect(s.add(90), 90);
      expect(s.shouldApply(), isTrue);
    });

    test('a wobble of a degree or two turns the map not at all', () {
      final s = HeadingSmoother();
      s.add(90);
      s.shouldApply();
      var turns = 0;
      for (final raw in [91.5, 88.5, 91.0, 89.0, 92.0, 88.0, 90.5, 89.5]) {
        s.add(raw);
        if (s.shouldApply()) turns++;
      }
      expect(turns, 0, reason: 'That is the shake Michael asked to be rid of.');
    });

    test('a real turn is followed, the short way across north', () {
      final s = HeadingSmoother();
      s.add(350);
      s.shouldApply();
      for (var i = 0; i < 40; i++) {
        s.add(20);
      }
      expect(
        s.value,
        closeTo(20, 0.5),
        reason:
            'Settles on the new heading, having gone through north rather '
            'than averaging 350 and 20 into 185.',
      );
      expect(s.shouldApply(), isTrue);
    });

    test('after a reset the next heading is taken as it is', () {
      final s = HeadingSmoother();
      s.add(10);
      s.reset();
      expect(s.value, isNull);
      expect(s.shouldApply(), isFalse);
      expect(s.add(200), 200);
    });
  });
}

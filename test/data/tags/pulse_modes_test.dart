import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/models/pulse_mode.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/models/tag_version.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **What a tag's pulse modes are, and what they refuse to be — task 11.187.**
///
/// Michael, 2026-09-07: *"The user should be able to toggle on/off up to three
/// modes but not fewer than 1."* The "not fewer than 1" half is the one worth
/// a test, because it is the half a reader has to be unable to break.
void main() {
  group('a tag always has at least one mode', () {
    test('a row that names no mode at all still reads as one', () {
      // The shape of a `Tags` row pushed by a build that predates schema v12,
      // which cannot know these columns exist. NULL there means "never said",
      // not "switched off" — slot 1 cannot be switched off.
      final modes = sampleTag().pulseModes;
      expect(modes, hasLength(1));
      expect(modes.single.slot, 1);
      expect(modes.single.name, defaultPulseModeNames[0]);
      expect(modes.single.rateBpm, 40);
    });

    test('a blank or whitespace slot-1 name reads as the default, never as '
        'no modes', () {
      for (final name in ['', '   ']) {
        final modes = sampleTag(pulseMode1Name: name).pulseModes;
        expect(modes, hasLength(1), reason: 'name was "$name"');
        expect(modes.single.name, defaultPulseModeNames[0]);
      }
    });

    test('there is no input that produces an empty list', () {
      // The guarantee stated as the thing it is: a total function whose
      // codomain excludes the empty list. A rule enforced by construction
      // cannot be forgotten by a caller.
      for (final slots in <List<(String?, double?)>>[
        [],
        [(null, null), (null, null), (null, null)],
        [('', null), ('', 90), ('   ', 120)],
        [(null, null), ('Mortality', 120), (null, null)],
      ]) {
        expect(buildPulseModes(slots), isNotEmpty, reason: '$slots');
      }
    });
  });

  group('a newly created tag gets the two defaults Michael chose', () {
    test('Normal at 60 bpm and Mortality at 120 bpm', () {
      // 2026-09-07: *"The default modes should be 'Normal' at 1 pulse per
      // second and Mortality at 2 pulses per second."* Converted to the stored
      // unit once, in `defaultPulseModeRatesBpm`, rather than at each site.
      final modes = sampleTag(pulseRate: null).withDefaultPulseModes().pulseModes;
      expect(modes.map((m) => m.name), ['Normal', 'Mortality']);
      expect(modes.map((m) => m.rateBpm), [60, 120]);
    });

    test('a rate the caller already knows is kept', () {
      // The paste screen has a rate from the payload; taking the default over
      // it would discard the one measurement the sender actually made.
      final modes = sampleTag(pulseRate: 52).withDefaultPulseModes().pulseModes;
      expect(modes.first.rateBpm, 52);
      expect(modes.last.rateBpm, 120);
    });

    test('there is no third default, because there is no third thing every '
        'collar has', () {
      expect(defaultPulseModeNames, hasLength(2));
      expect(defaultPulseModeRatesBpm, hasLength(2));
      expect(
        sampleTag().withDefaultPulseModes().pulseModes.map((m) => m.slot),
        [1, 2],
      );
    });
  });

  group('a mode exists exactly when it is named', () {
    test('slots 2 and 3 appear only when they have a name', () {
      final oneMode = sampleTag().pulseModes;
      expect(oneMode.map((m) => m.slot), [1]);

      final threeModes = sampleTag(
        pulseMode1Name: 'Normal',
        pulseMode2Name: 'Mortality',
        pulseMode2RateBpm: 120,
        pulseMode3Name: 'Fast beacon',
        pulseMode3RateBpm: 180,
      ).pulseModes;
      expect(threeModes.map((m) => m.slot), [1, 2, 3]);
      expect(threeModes.map((m) => m.name), [
        'Normal',
        'Mortality',
        'Fast beacon',
      ]);
      expect(threeModes.map((m) => m.rateBpm), [40, 120, 180]);
    });

    test('a rate sitting in a slot with no name is inert', () {
      // The one way the five columns can disagree with each other, and it
      // fails in the harmless direction: nothing reads a rate without first
      // having a mode to read it for. Recorded as a test rather than left to
      // be rediscovered as a defect.
      final modes = sampleTag(pulseMode2RateBpm: 120).pulseModes;
      expect(modes.map((m) => m.slot), [1]);
      expect(pulseModeAt(modes, 2), isNull);
    });

    test('the slot number survives a rename, which is why an observation '
        'stores it', () {
      final before = sampleTag(
        pulseMode1Name: 'Normal',
        pulseMode2Name: 'Mortality',
        pulseMode2RateBpm: 120,
      );
      final after = before.copyWith(pulseMode2Name: 'Mort.');
      expect(pulseModeAt(after.pulseModes, 2)!.name, 'Mort.');
      expect(pulseModeAt(before.pulseModes, 2)!.slot,
          pulseModeAt(after.pulseModes, 2)!.slot);
    });
  });

  group('a mode switched off does not rewrite the records that used it', () {
    test('the version still says what the tag read, and the tag no longer '
        'offers it', () {
      // The whole point of `Tag_Versions`, applied to modes. Somebody turns
      // mortality off in September; a bearing heard on it in June still reads
      // "Mortality", because the version row it points at still says so.
      final version = sampleTagVersion(
        pulseMode1Name: 'Normal',
        pulseMode2Name: 'Mortality',
        pulseMode2RateBpm: 120,
      );
      final tagNow = sampleTag(pulseMode1Name: 'Normal');
      final recorded = RecordedTagState(tag: tagNow, version: version);

      expect(
        recorded.recordedPulseModeName(
          storedSlot: 2,
          legacy: SignalType.mortalitySignal,
        ),
        'Mortality',
      );
      expect(
        recorded.recordedPulseModeRateBpm(
          storedSlot: 2,
          legacy: SignalType.mortalitySignal,
        ),
        120,
      );
      // And the collar itself no longer offers it, which is what the person
      // asked for.
      expect(pulseModeAt(tagNow.pulseModes, 2), isNull);
      // The two disagreeing is the *point*, and this is the assertion that
      // says a future reader must not reconcile them.
      expect(recorded.differsFromCurrent, isTrue);
    });

    test('a record whose version this device does not hold says which mode, '
        'and declines to invent what it was called', () {
      final recorded = RecordedTagState(
        tag: sampleTag(pulseMode1Name: 'Normal', pulseMode3Name: 'Fast'),
        version: null,
      );
      // Slot 3 with nothing to name it. **Not "Fast"** — the collar in front of
      // you today is not evidence about what its modes were called last season.
      expect(
        recorded.recordedPulseModeName(
          storedSlot: 3,
          legacy: SignalType.regularPulse,
        ),
        'Mode 3',
      );
      expect(
        recorded.recordedPulseModeRateBpm(
          storedSlot: 3,
          legacy: SignalType.regularPulse,
        ),
        isNull,
      );
    });

    test('a record from before schema v12 adopts the default names, which is '
        "Michael's answer 3", () {
      // No version, no stored slot: the record's mode was one of two words
      // fixed in the build that wrote it, so naming them is transcription of a
      // constant rather than a guess about a tag.
      final recorded = RecordedTagState(tag: sampleTag(), version: null);
      expect(
        recorded.recordedPulseModeName(
          storedSlot: null,
          legacy: SignalType.regularPulse,
        ),
        'Normal',
      );
      expect(
        recorded.recordedPulseModeName(
          storedSlot: null,
          legacy: SignalType.mortalitySignal,
        ),
        'Mortality',
      );
      // The word this task removes from the app.
      expect(
        recorded.recordedPulseModeName(
          storedSlot: null,
          legacy: SignalType.regularPulse,
        ),
        isNot('Regular'),
      );
    });
  });

  group('editing modes asks the correction-or-change question', () {
    Tag threeModes() => sampleTag(
          pulseMode1Name: 'Normal',
          pulseMode2Name: 'Mortality',
          pulseMode2RateBpm: 120,
        );

    TagVersion versionOf(Tag tag) => TagVersion.of(
          tag,
          tagVersionId: 'v',
          effectiveFrom: DateTime.utc(2026),
          sync: sampleSync(),
        );

    test('renaming a mode, re-rating one, or switching one off all count', () {
      final before = threeModes();
      final version = versionOf(before);
      for (final after in [
        before.copyWith(pulseMode2Name: 'Mort.'),
        before.copyWith(pulseMode2RateBpm: 90),
        before.copyWith(pulseMode2Name: null, pulseMode2RateBpm: null),
        before.copyWith(pulseMode3Name: 'Fast', pulseMode3RateBpm: 180),
        before.copyWith(pulseRate: 44),
      ]) {
        expect(version.matches(after), isFalse, reason: '$after');
      }
    });

    test('a recolour still asks nothing — including on a tag whose slot-1 '
        'name was never written down', () {
      // The regression this group exists for. Comparing the raw columns rather
      // than the modes made "NULL" and "Normal" different tags, so a tag row
      // that predates v12 raised the mistake-or-change dialog on a recolour —
      // a question about earlier bearings, asked because of a colour.
      final before = sampleTag();
      final version = versionOf(before);
      expect(version.matches(before.copyWith(colorHex: '#123456')), isTrue);
      expect(
        version.matches(before.copyWith(pulseMode1Name: 'Normal')),
        isTrue,
        reason:
            'A slot-1 name of NULL and one of "Normal" are the same tag: NULL '
            'means "never said" and reads as the default everywhere.',
      );
    });

    test('a rate orphaned in an unnamed slot is not a change to anything a '
        'bearing was recorded against', () {
      final before = threeModes();
      final version = versionOf(before);
      expect(
        version.matches(before.copyWith(pulseMode3RateBpm: 180)),
        isTrue,
        reason: 'Slot 3 has no name, so nothing ever reads that rate.',
      );
    });
  });
}

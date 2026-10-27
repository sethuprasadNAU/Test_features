import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/data/models/tag_version.dart';
import 'package:tritrack/data/sharing/observation_share.dart';

import '../fixtures.dart';

void main() {
  group('ObservationShare round-trip', () {
    test('encode then decode recovers every field', () {
      final obs = sampleObservation();
      final tag = sampleTag();
      final user = sampleUser();

      final payload = ObservationShare.encode(obs, tag: tag, observer: user);
      expect(payload, startsWith('TT1:'));

      final shared = ObservationShare.decode(payload);
      expect(shared.payloadVersion, 4);
      expect(shared.observerName, 'Sam Ranger');
      expect(shared.latitude, obs.latitude);
      expect(shared.longitude, obs.longitude);
      expect(shared.elevation, obs.elevation);
      expect(shared.tagFrequencyMhz, tag.frequencyMhz);
      expect(shared.tagPulseRate, tag.pulseRate);
      expect(shared.tagName, tag.tagName);
      expect(shared.observationType, ObservationType.directional);
      expect(shared.magneticBearing, obs.magneticBearing);
      expect(shared.trueNorthBearing, obs.trueNorthBearing);
      expect(shared.signalType, SignalType.regularPulse);
      expect(shared.signalStrength, SignalStrength.medium);
      expect(shared.bearingQuality, BearingQuality.good);
      expect(shared.notes, 'clear signal');
    });

    group('the pulse mode (v3, task 11.187)', () {
      test('the slot and the words the sender saw both travel', () {
        final obs = sampleObservation(pulseMode: 3);
        final tag = sampleTag(
          pulseMode1Name: 'Normal',
          pulseMode3Name: 'Fast beacon',
          pulseMode3RateBpm: 180,
        );
        final shared = ObservationShare.decode(
          ObservationShare.encode(
            obs,
            tag: tag,
            observer: sampleUser(),
            recorded: RecordedTagState(
              tag: tag,
              version: sampleTagVersion(
                pulseMode1Name: 'Normal',
                pulseMode3Name: 'Fast beacon',
                pulseMode3RateBpm: 180,
              ),
            ),
          ),
        );
        expect(shared.pulseModeSlot, 3);
        // **The words are the half a person can act on.** "Fast beacon" means
        // the same thing on both devices; "slot 3" does not.
        expect(shared.pulseModeName, 'Fast beacon');
        expect(shared.pulseModeDescription, 'Fast beacon');
      });

      test('a payload whose sender did not know the mode says so rather than '
          "borrowing this device's names", () {
        // No `recorded` state: the sender's bearing predates schema v9 or its
        // version row never reached them. Completing the sentence from the
        // local tag would put a name on the record nobody who took it saw.
        final shared = ObservationShare.decode(
          ObservationShare.encode(
            sampleObservation(pulseMode: 2),
            tag: sampleTag(pulseMode2Name: 'Mortality', pulseMode2RateBpm: 120),
            observer: sampleUser(),
          ),
        );
        expect(shared.pulseModeSlot, 2);
        expect(shared.pulseModeName, isNull);
        expect(shared.pulseModeDescription, 'not recorded in this payload');
      });

      test('a v2 payload carries no mode and is not given one', () {
        final shared =
            ObservationShare.decode('TT1:${_b64(_validV2JsonWith({}))}');
        expect(shared.payloadVersion, 2);
        expect(shared.pulseModeSlot, isNull);
        expect(shared.pulseModeName, isNull);
        expect(shared.pulseModeDescription, 'not recorded in this payload');
      });

      test('a slot outside 1..3 is dropped rather than refusing the whole '
          'bearing', () {
        // The field is display-only — nothing is written from it — so a
        // nonsense value costs a sentence on one screen. Refusing the payload
        // would lose a real bearing over a cosmetic fault.
        for (final bad in [0, 4, 'two', -1]) {
          final shared = ObservationShare.decode(
            'TT1:${_b64(_validV2JsonWith({'v': 3, 'pulse_mode': bad}))}',
          );
          expect(shared.pulseModeSlot, isNull, reason: 'pulse_mode was $bad');
        }
      });
    });

    /// **Task 11.193 — the flag that says the signal itself sounded wrong.**
    ///
    /// It travels and it is *written*, unlike the pulse mode above, and the
    /// difference is what the value is about. A slot number names a mode on
    /// the sender's tag and the replica is relabelled onto whichever local tag
    /// the receiver picked; this is what a person heard at a time and a place,
    /// and it means the same thing on both devices. It is very often the whole
    /// reason a record is being shared.
    group('the irregular-signal flag (v4, task 11.193)', () {
      SharedObservation roundTrip(bool? flag) => ObservationShare.decode(
            ObservationShare.encode(
              sampleObservation(signalIrregular: flag),
              tag: sampleTag(),
              observer: sampleUser(),
            ),
          );

      test('all three answers survive, and false is not null', () {
        expect(roundTrip(true).signalIrregular, isTrue);
        expect(
          roundTrip(false).signalIrregular,
          isFalse,
          reason: '"I listened and heard nothing wrong" is a statement the '
              'sender made. Collapsing it to "not recorded" would throw away '
              'the more common of the two real answers.',
        );
        expect(
          roundTrip(null).signalIrregular,
          isNull,
          reason: 'And a bearing nobody was asked about stays unasked.',
        );
      });

      test('a v1, v2 or v3 payload is not given an answer it never carried',
          () {
        for (final version in [1, 2, 3]) {
          final shared = ObservationShare.decode(
            'TT1:${_b64(_validV2JsonWith({'v': version}))}',
          );
          expect(
            shared.signalIrregular,
            isNull,
            reason: 'v$version had no such field, and "the signal was fine" is '
                'not what a payload that could not say it means.',
          );
        }
      });

      test('anything that is not a yes or a no reads as no answer, rather than '
          'costing the whole bearing', () {
        // One bit of context on a record whose bearing, position and time are
        // the reason it was sent. `NumericBound.flag` is what refuses a bad
        // value on the sync wire, where the column is written directly.
        for (final bad in [1, 'true', 'yes', <String>[]]) {
          final shared = ObservationShare.decode(
            'TT1:${_b64(_validV2JsonWith({'v': 4, 'signal_irregular': bad}))}',
          );
          expect(shared.signalIrregular, isNull,
              reason: 'signal_irregular was $bad');
        }
      });
    });

    test('null optionals (omnidirectional detection) survive the round-trip', () {
      final obs = sampleMinimalObservation();
      final tag = sampleTag();
      final user = sampleUser();
      final shared = ObservationShare.decode(ObservationShare.encode(obs, tag: tag, observer: user));
      expect(shared.magneticBearing, isNull);
      expect(shared.bearingQuality, isNull);
      expect(shared.notes, isNull);
    });

    test('surrounding whitespace from a copy/paste round-trip is tolerated', () {
      final obs = sampleObservation();
      final payload = ObservationShare.encode(obs, tag: sampleTag(), observer: sampleUser());
      final withWhitespace = '  \n$payload\n  ';
      expect(() => ObservationShare.decode(withWhitespace), returnsNormally);
    });
  });

  group('v2 identity, provenance, and sync clock', () {
    test('round-trips the identity block and the sender sync clock verbatim', () {
      final obs = sampleObservation();
      final user = sampleUser();
      final shared = ObservationShare.decode(
        ObservationShare.encode(obs, tag: sampleTag(), observer: user),
      );

      expect(shared.canReplicate, isTrue);
      final id = shared.identity!;
      expect(id.observationId, obs.observationId);
      expect(id.observerUserId, user.userId);
      expect(id.observerEmail, user.email);
      expect(id.positionSource, obs.positionSource);
      expect(id.positionAccuracyM, obs.positionAccuracyM);
      // The clock must be copied, not re-initialized: a replica written with
      // SyncMeta.initial could outrank the original and clobber later edits.
      expect(id.sync.createdAt, obs.sync.createdAt);
      expect(id.sync.updatedAt, obs.sync.updatedAt);
      expect(id.sync.revision, obs.sync.revision);
      expect(id.sync.lastModifiedBy, obs.sync.lastModifiedBy);
      expect(id.sync.originDeviceId, obs.sync.originDeviceId);
      expect(id.sync.deletedAt, isNull);
    });

    test('a non-zero revision survives rather than resetting to a fresh clock', () {
      final obs = sampleObservation().copyWith(
        sync: sampleSync().copyWith(
          revision: 7,
          updatedAt: DateTime.utc(2026, 7, 20, 9, 0, 0),
        ),
      );
      final shared = ObservationShare.decode(
        ObservationShare.encode(obs, tag: sampleTag(), observer: sampleUser()),
      );
      expect(shared.identity!.sync.revision, 7);
      expect(shared.identity!.sync.updatedAt, DateTime.utc(2026, 7, 20, 9, 0, 0));
    });

    test('a null position_accuracy_m round-trips as null, not zero', () {
      final shared = ObservationShare.decode(ObservationShare.encode(
        sampleMinimalObservation(),
        tag: sampleTag(),
        observer: sampleUser(),
      ));
      expect(shared.identity!.positionAccuracyM, isNull);
    });

    test('observer_email is normalized on decode so both sides share one anchor', () {
      final json = _validV2JsonWith({'observer_email': '  Coco@Example.COM '});
      final shared = ObservationShare.decode('TT1:${_b64(json)}');
      expect(shared.identity!.observerEmail, 'coco@example.com');
    });

    test('position_source is preserved rather than re-derived by the receiver', () {
      final obs = sampleObservation().copyWith(positionSource: PositionSource.manualPin);
      final shared = ObservationShare.decode(
        ObservationShare.encode(obs, tag: sampleTag(), observer: sampleUser()),
      );
      expect(shared.identity!.positionSource, PositionSource.manualPin);
    });
  });

  group('v1 compatibility', () {
    test('a v1 payload still decodes but is clearly identity-less', () {
      final shared = ObservationShare.decode('TT1:${_b64(_validJsonWith({}))}');
      expect(shared.payloadVersion, 1);
      expect(shared.identity, isNull);
      expect(shared.canReplicate, isFalse);
      // The observation content itself must still be usable for preview/save.
      expect(shared.observerName, 'Sam Ranger');
      expect(shared.latitude, 35.19);
    });

    test('a v2 payload is marked replicable, distinguishing it from v1', () {
      final v1 = ObservationShare.decode('TT1:${_b64(_validJsonWith({}))}');
      final v2 = ObservationShare.decode('TT1:${_b64(_validV2JsonWith({}))}');
      expect(v1.canReplicate, isFalse);
      expect(v2.canReplicate, isTrue);
    });

    test('a payload newer than this build fails with an actionable message', () {
      expect(
        () => ObservationShare.decode('TT1:${_b64(_validV2JsonWith({'v': 5}))}'),
        throwsA(isA<ObservationShareFormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains('v5'), contains('newer than this app supports')),
        )),
      );
    });
  });

  group('v2 rejects hostile or incomplete identity fields', () {
    test('a v2 payload missing observation_id is refused, not half-replicated', () {
      final json = _v2Map()..remove('observation_id');
      expect(() => ObservationShare.decode('TT1:${_b64(jsonEncode(json))}'),
          throwsA(isA<ObservationShareFormatException>()));
    });

    for (final key in ['observer_user_id', 'observer_email', 'position_source', 'created_at', 'updated_at', 'revision']) {
      test('a v2 payload missing $key is refused', () {
        final json = _v2Map()..remove(key);
        expect(() => ObservationShare.decode('TT1:${_b64(jsonEncode(json))}'),
            throwsA(isA<ObservationShareFormatException>()));
      });
    }

    test('an id carrying SQL/path punctuation is refused', () {
      for (final hostile in ["obs'; DROP TABLE observations;--", '../../etc/passwd', 'a b']) {
        expect(() => ObservationShare.decode('TT1:${_b64(_validV2JsonWith({'observation_id': hostile}))}'),
            throwsA(isA<ObservationShareFormatException>()),
            reason: hostile);
      }
    });

    test('an absurdly long id is refused', () {
      final json = _validV2JsonWith({'observer_user_id': 'a' * 500});
      expect(() => ObservationShare.decode('TT1:${_b64(json)}'),
          throwsA(isA<ObservationShareFormatException>()));
    });

    test('a malformed email is refused rather than becoming a junk dedup key', () {
      for (final bad in ['not-an-email', 'no@domain', 'two@@at.com', 'spaces in@example.com']) {
        expect(() => ObservationShare.decode('TT1:${_b64(_validV2JsonWith({'observer_email': bad}))}'),
            throwsA(isA<ObservationShareFormatException>()),
            reason: bad);
      }
    });

    test('an unknown position_source is refused', () {
      final json = _validV2JsonWith({'position_source': 'telepathy'});
      expect(() => ObservationShare.decode('TT1:${_b64(json)}'),
          throwsA(isA<ObservationShareFormatException>()));
    });

    test('a negative revision is refused', () {
      final json = _validV2JsonWith({'revision': -1});
      expect(() => ObservationShare.decode('TT1:${_b64(json)}'),
          throwsA(isA<ObservationShareFormatException>()));
    });

    test('a negative position_accuracy_m is refused', () {
      final json = _validV2JsonWith({'position_accuracy_m': -5.0});
      expect(() => ObservationShare.decode('TT1:${_b64(json)}'),
          throwsA(isA<ObservationShareFormatException>()));
    });

    test('updated_at before created_at is refused as an inconsistent clock', () {
      final json = _validV2JsonWith({
        'created_at': '2026-07-16T18:30:00.000Z',
        'updated_at': '2026-07-01T00:00:00.000Z',
      });
      expect(() => ObservationShare.decode('TT1:${_b64(json)}'),
          throwsA(isA<ObservationShareFormatException>()));
    });

    test('an unparseable sync timestamp is refused', () {
      final json = _validV2JsonWith({'updated_at': 'last tuesday'});
      expect(() => ObservationShare.decode('TT1:${_b64(json)}'),
          throwsA(isA<ObservationShareFormatException>()));
    });
  });

  group('ObservationShare.decode rejects malformed input', () {
    test('missing the TT1: prefix', () {
      expect(() => ObservationShare.decode('just some random text'),
          throwsA(isA<ObservationShareFormatException>()));
    });

    test('prefix present but not valid base64/JSON', () {
      expect(() => ObservationShare.decode('TT1:not-valid-base64!!!'),
          throwsA(isA<ObservationShareFormatException>()));
    });

    test('valid base64 JSON but missing required fields', () {
      final payload = 'TT1:${_b64('{"v":1}')}';
      expect(() => ObservationShare.decode(payload),
          throwsA(isA<ObservationShareFormatException>()));
    });

    test('a newer format version is rejected', () {
      final payload = 'TT1:${_b64('{"v":99}')}';
      expect(() => ObservationShare.decode(payload),
          throwsA(isA<ObservationShareFormatException>()));
    });

    test('out-of-range latitude is rejected rather than placed on the map', () {
      final json = _validJsonWith({'latitude': 999.0});
      expect(() => ObservationShare.decode('TT1:${_b64(json)}'),
          throwsA(isA<ObservationShareFormatException>()));
    });

    test('an unknown enum value is rejected', () {
      final json = _validJsonWith({'signal_strength': 'ludicrous'});
      expect(() => ObservationShare.decode('TT1:${_b64(json)}'),
          throwsA(isA<ObservationShareFormatException>()));
    });
  });

  group('SharedObservation.matchesTag — the "tag key" match', () {
    test('matches on frequency + name, tolerant of float noise', () {
      final tag = sampleTag();
      final shared = ObservationShare.decode(
        ObservationShare.encode(sampleObservation(), tag: tag, observer: sampleUser()),
      );
      expect(shared.matchesTag(tag), isTrue);
    });

    test('does not match a different frequency or name', () {
      final tag = sampleTag();
      final shared = ObservationShare.decode(
        ObservationShare.encode(sampleObservation(), tag: tag, observer: sampleUser()),
      );
      final otherFreq = tag.copyWith(frequencyMhz: tag.frequencyMhz + 1.0);
      final otherName = tag.copyWith(tagName: 'Different');
      expect(shared.matchesTag(otherFreq), isFalse);
      expect(shared.matchesTag(otherName), isFalse);
    });
  });
}

String _b64(String json) => base64Encode(utf8.encode(json));

/// A minimally-valid share JSON string with [overrides] applied — used to
/// test individual field-validation failures without repeating the whole
/// schema in every test.
String _validJsonWith(Map<String, Object?> overrides) {
  final base = <String, Object?>{
    'v': 1,
    'observer_name': 'Sam Ranger',
    'timestamp_utc': '2026-07-16T18:30:00.000Z',
    'timestamp_local': '2026-07-16T11:30:00.000',
    'timezone_offset': '-07:00',
    'latitude': 35.19,
    'longitude': -111.62,
    'elevation': 2103.0,
    'tag_frequency_mhz': 150.325,
    'tag_pulse_rate': 40.0,
    'tag_name': 'Coco',
    'observation_type': 'directional',
    'magnetic_bearing': 145.0,
    'true_north_bearing': 155.2,
    'bearing_uncertainty': 12.0,
    'signal_type': 'regular_pulse',
    'signal_strength': 'medium',
    'bearing_quality': 'good',
    'notes': 'clear signal',
  };
  base.addAll(overrides);
  return jsonEncode(base);
}

/// A minimally-valid **v2** share payload as a mutable map, so tests can both
/// override fields and remove them (the "v2 must carry the whole identity
/// block" cases).
Map<String, Object?> _v2Map([Map<String, Object?> overrides = const {}]) {
  final base = <String, Object?>{
    ...jsonDecode(_validJsonWith({})) as Map<String, Object?>,
    'v': 2,
    'observation_id': 'obs-1',
    'observer_user_id': 'user-1',
    'observer_email': 'coco@example.com',
    'position_source': 'gps_fix',
    'position_accuracy_m': 8.5,
    'created_at': '2026-07-16T18:30:00.000Z',
    'updated_at': '2026-07-16T18:30:00.000Z',
    'revision': 0,
    'last_modified_by': 'user-1',
    'origin_device_id': 'device-A',
  };
  base.addAll(overrides);
  return base;
}

String _validV2JsonWith(Map<String, Object?> overrides) => jsonEncode(_v2Map(overrides));

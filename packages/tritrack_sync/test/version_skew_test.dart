import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// The version-skew policy: same schema **major** syncs, different major is
/// refused, and the minor may differ freely (task 10.11, revised by 10.18).
///
/// The tests below are as much a record of the *decision* as a check on the
/// code. What they pin down cannot be revisited once devices are in the field,
/// so if a future change makes one of these fail, the question to ask is whether
/// the policy changed, not whether the assertion is stale.
///
/// 10.11 required exact equality on a single integer, on the grounds that a
/// partial sync destroys data — an older peer that drops a column it cannot
/// store writes an empty value back over another device's contribution. That
/// reasoning was right; the conclusion was too strong. An older peer does not
/// have to drop the column. Held verbatim and returned untouched (the app's
/// `UnknownColumnStore`), the row survives the trip whole, and the destruction
/// the exact-equality rule existed to prevent cannot occur. What remains
/// genuinely incompatible — deletes, renames, retypes, reused names, tightened
/// validation — is what the major is for.
void main() {
  Map<String, Object?> envelopeJson({int? protocol, int? schema, int? major}) =>
      {
        'envelope': kSyncEnvelopeId,
        'protocol_version': protocol ?? syncProtocolVersion,
        'schema_version': schema ?? latestSchemaVersion,
        'schema_major': major ?? schemaMajorVersion,
      };

  group('schema version skew', () {
    test('matching versions decode normally', () {
      final envelope = SyncEnvelope.fromJson(envelopeJson());
      expect(envelope.schemaVersion, latestSchemaVersion);
      expect(envelope.schemaMajor, schemaMajorVersion);
      expect(envelope.protocolVersion, syncProtocolVersion);
    });

    test('a peer one MINOR behind is accepted, not refused', () {
      // The revision, in one assertion. This is the case that used to strand a
      // device for an entire season over an added column it would never have
      // needed to read.
      final envelope = SyncEnvelope.fromJson(
        envelopeJson(schema: latestSchemaVersion - 1),
      );
      expect(envelope.schemaVersion, latestSchemaVersion - 1);
    });

    test('a peer one MINOR ahead is accepted too', () {
      // The direction that actually matters in the field: the server upgrades
      // first (standing rule 5), so every un-updated app is talking to a server
      // ahead of it. Refusing this is what made a schema bump a fleet-wide
      // outage.
      final envelope = SyncEnvelope.fromJson(
        envelopeJson(schema: latestSchemaVersion + 1),
      );
      expect(envelope.schemaVersion, latestSchemaVersion + 1);
    });

    test('a peer on a different MAJOR is refused, both directions', () {
      // A major bump means a change preservation cannot absorb — a deleted or
      // renamed column, a retyped one, a name reused for a new meaning. There
      // is no safe partial behaviour for any of those, so this stays a refusal.
      expect(
        () => SyncEnvelope.fromJson(
          envelopeJson(major: schemaMajorVersion + 1),
        ),
        throwsA(isA<SyncSchemaVersionException>()),
      );
      expect(
        () => SyncEnvelope.fromJson(
          envelopeJson(major: schemaMajorVersion - 1),
        ),
        throwsA(isA<SyncSchemaVersionException>()),
      );
    });

    test('an envelope without a major is a protocol error, not a guess', () {
      // Defaulting the major would let a payload from something that is not a
      // TriTrack peer — or from a build predating this policy — through the one
      // gate that decides compatibility.
      final json = envelopeJson()..remove('schema_major');
      expect(
        () => SyncEnvelope.fromJson(json),
        throwsA(isA<SyncProtocolException>()),
      );
    });

    test('the refusal records which side is behind', () {
      // Direction is what makes the message actionable: "update the app" and
      // "update the server" are different instructions to different people,
      // and guessing wrong sends someone chasing an update that does not
      // exist.
      try {
        SyncEnvelope.fromJson(envelopeJson(major: schemaMajorVersion + 1));
        fail('expected a schema version refusal');
      } on SyncSchemaVersionException catch (error) {
        expect(error.receivedMajor, schemaMajorVersion + 1);
        expect(error.supportedMajor, schemaMajorVersion);
        expect(error.supported, latestSchemaVersion);
        expect(
          error.senderIsOlder,
          isFalse,
          reason: 'the peer is ahead of this build',
        );
      }

      try {
        SyncEnvelope.fromJson(envelopeJson(major: schemaMajorVersion - 1));
        fail('expected a schema version refusal');
      } on SyncSchemaVersionException catch (error) {
        expect(
          error.senderIsOlder,
          isTrue,
          reason: 'the peer is behind this build',
        );
      }
    });

    test('the major decides direction even when the minor disagrees', () {
      // A peer on an older major can still carry a higher minor — minors are a
      // monotonic migration counter and do not reset when the major moves. If
      // the minor decided, this peer would be reported as ahead and its
      // operator told to update the wrong side.
      try {
        SyncEnvelope.fromJson(
          envelopeJson(
            major: schemaMajorVersion - 1,
            schema: latestSchemaVersion + 10,
          ),
        );
        fail('expected a schema version refusal');
      } on SyncSchemaVersionException catch (error) {
        expect(error.senderIsOlder, isTrue);
      }
    });

    test('a schema refusal is distinct from a protocol refusal', () {
      // They are remedied differently (update the app vs. a wire-format
      // break), so collapsing them into one exception would make the more
      // common case unactionable.
      expect(
        () => SyncEnvelope.fromJson(
          envelopeJson(major: schemaMajorVersion + 1),
        ),
        throwsA(isNot(isA<SyncProtocolVersionException>())),
      );
      expect(
        () => SyncEnvelope.fromJson(
          envelopeJson(protocol: syncProtocolVersion + 1),
        ),
        throwsA(isNot(isA<SyncSchemaVersionException>())),
      );
    });

    test('protocol version is checked before schema version', () {
      // A payload wrong on both counts is a protocol problem: the schema
      // number inside a shape this build cannot parse is not meaningful, and
      // reporting it would send debugging to the wrong layer.
      expect(
        () => SyncEnvelope.fromJson(
          envelopeJson(
            protocol: syncProtocolVersion + 1,
            major: schemaMajorVersion + 1,
          ),
        ),
        throwsA(isA<SyncProtocolVersionException>()),
      );
    });

    test('every request and response type is guarded, not just some', () {
      // The check lives in `SyncEnvelope.fromJson` precisely so no endpoint
      // can forget it. This asserts that placement rather than trusting it.
      final skewed = envelopeJson(major: schemaMajorVersion + 1);
      expect(
        () => SyncPushRequest.fromJson({
          ...skewed,
          'project_id': 'p',
          'device_id': 'd',
          'rows': <String, Object?>{},
        }),
        throwsA(isA<SyncSchemaVersionException>()),
      );
      expect(
        () => SyncPullRequest.fromJson({
          ...skewed,
          'project_id': 'p',
          'device_id': 'd',
          'cursor': 0,
        }),
        throwsA(isA<SyncSchemaVersionException>()),
      );
      expect(
        () => SyncPullResponse.fromJson({
          ...skewed,
          'rows': <String, Object?>{},
          'next_cursor': 0,
          'remaining': 0,
        }),
        throwsA(isA<SyncSchemaVersionException>()),
      );
      expect(
        () => SyncPushResponse.fromJson({
          ...skewed,
          'applied': 0,
          'outcomes': <String, Object?>{},
        }),
        throwsA(isA<SyncSchemaVersionException>()),
      );
      expect(
        () => SyncAckRequest.fromJson({
          ...skewed,
          'project_id': 'p',
          'device_id': 'd',
          'cursor': 0,
        }),
        throwsA(isA<SyncSchemaVersionException>()),
      );
      expect(
        () => ProjectDirectoryResponse.fromJson({
          ...skewed,
          'projects': <Object?>[],
        }),
        throwsA(isA<SyncSchemaVersionException>()),
      );
    });
  });

  group('tombstone retention policy', () {
    test('the window is long enough for a shelved-between-seasons device', () {
      // The scenario the number is sized against: last synced early in season
      // one, shelved over the off-season, brought back late in season two.
      // That is ~18 months; the window has to clear it with room to spare.
      const shelvedBetweenSeasons = Duration(days: 548);
      expect(tombstoneRetention, greaterThan(shelvedBetweenSeasons));
    });

    test('purging is held back by active devices, not by age alone', () {
      // Age alone says nothing about whether anyone still needs the tombstone.
      // This constant is the documentation anchor for that; the behaviour it
      // describes is exercised against real Postgres in the server suite.
      expect(tombstonePurgeIsHeldBackByActiveDevices, isTrue);
    });
  });
}

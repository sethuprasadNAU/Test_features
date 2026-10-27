import 'dart:convert';

import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

void main() {
  group('envelope', () {
    test('the marker is stable across payload versions', () {
      // Task 6.2's precedent: the envelope identifies "a TriTrack sync
      // message" and does not move; the protocol version is what changes.
      expect(kSyncEnvelopeId, 'tritrack_sync');
    });

    test('protocol version and schema version are independent', () {
      // Conflating them would force a protocol break on every schema change.
      final envelope = const SyncEnvelope().toJson();
      expect(envelope['protocol_version'], syncProtocolVersion);
      expect(envelope['schema_version'], latestSchemaVersion);
      expect(envelope.containsKey('protocol_version'), isTrue);
      expect(envelope.containsKey('schema_version'), isTrue);
    });

    test('a foreign payload is rejected as not-a-sync-envelope', () {
      // Reported as identity, not version, so debugging starts in the right
      // place.
      expect(
        () => SyncEnvelope.fromJson({'envelope': 'something_else'}),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(
        () => SyncEnvelope.fromJson({}),
        throwsA(isA<SyncProtocolException>()),
      );
    });

    test('a version mismatch throws a distinct, actionable exception', () {
      // Task 10.11 needs to answer "update to sync" rather than surfacing a
      // parse failure.
      expect(
        () => SyncEnvelope.fromJson({
          'envelope': kSyncEnvelopeId,
          'protocol_version': syncProtocolVersion + 1,
          'schema_version': latestSchemaVersion,
        }),
        throwsA(isA<SyncProtocolVersionException>()),
      );
    });

    test('a missing version is a protocol error, not a default', () {
      expect(
        () => SyncEnvelope.fromJson({'envelope': kSyncEnvelopeId}),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(
        () => SyncEnvelope.fromJson({
          'envelope': kSyncEnvelopeId,
          'protocol_version': syncProtocolVersion,
        }),
        throwsA(isA<SyncProtocolException>()),
      );
    });
  });

  group('SyncCursorKey', () {
    // The single most important detail in the protocol. A per-user cursor lets
    // one device advance the shared position past rows another never received,
    // and those rows are then never offered again — silent loss that presents
    // as nothing having happened.
    test('two devices of one user are different cursors', () {
      const laptop = SyncCursorKey(
        userId: 'user-1',
        deviceId: 'laptop',
        projectId: 'proj-1',
      );
      const phone = SyncCursorKey(
        userId: 'user-1',
        deviceId: 'phone',
        projectId: 'proj-1',
      );
      expect(laptop, isNot(phone));
      expect({laptop, phone}, hasLength(2));
    });

    test('two projects on one device are different cursors', () {
      const a = SyncCursorKey(
        userId: 'user-1',
        deviceId: 'laptop',
        projectId: 'proj-1',
      );
      const b = SyncCursorKey(
        userId: 'user-1',
        deviceId: 'laptop',
        projectId: 'proj-2',
      );
      expect(a, isNot(b));
    });

    test('the same triple is the same cursor', () {
      const a = SyncCursorKey(userId: 'u', deviceId: 'd', projectId: 'p');
      const b = SyncCursorKey(userId: 'u', deviceId: 'd', projectId: 'p');
      expect(a, b);
      // ignore: equal_elements_in_set — the point is that they collapse.
      expect(<SyncCursorKey>{a, b}, hasLength(1));
    });
  });

  group('push request', () {
    test('round-trips through JSON', () {
      final request = SyncPushRequest(
        projectId: 'proj-1',
        deviceId: 'device-A',
        rows: {
          Tables.observations: [
            {'observation_id': 'obs-1', 'revision': 2},
          ],
        },
      );
      final decoded = SyncPushRequest.fromJson(
        jsonDecode(jsonEncode(request.toJson())) as Map<String, Object?>,
      );
      expect(decoded.projectId, 'proj-1');
      expect(decoded.deviceId, 'device-A');
      expect(decoded.rowCount, 1);
      expect(
        decoded.rows[Tables.observations]!.single['observation_id'],
        'obs-1',
      );
    });

    test('a missing project or device is a protocol error', () {
      expect(
        () => SyncPushRequest.fromJson({
          ...const SyncEnvelope().toJson(),
          'device_id': 'device-A',
          'rows': <String, Object?>{},
        }),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(
        () => SyncPushRequest.fromJson({
          ...const SyncEnvelope().toJson(),
          'project_id': 'proj-1',
          'rows': <String, Object?>{},
        }),
        throwsA(isA<SyncProtocolException>()),
      );
    });
  });

  group('pull request', () {
    test('a client may ask for a smaller batch', () {
      final decoded = SyncPullRequest.fromJson({
        ...const SyncEnvelope().toJson(),
        'project_id': 'p',
        'device_id': 'd',
        'cursor': 5,
        'batch_size': 20,
      });
      expect(decoded.batchSize, 20);
      expect(decoded.cursor, 5);
    });

    test('a client cannot ask for an unbounded batch', () {
      // The server has to be able to bound its own response regardless of what
      // it is asked for; an unbounded request is a memory-exhaustion primitive.
      final decoded = SyncPullRequest.fromJson({
        ...const SyncEnvelope().toJson(),
        'project_id': 'p',
        'device_id': 'd',
        'batch_size': 10_000_000,
      });
      expect(decoded.batchSize, maxSyncBatchSize);
    });

    test('a nonsensical batch size is clamped, not honoured', () {
      for (final requested in [0, -1, -1000]) {
        final decoded = SyncPullRequest.fromJson({
          ...const SyncEnvelope().toJson(),
          'project_id': 'p',
          'device_id': 'd',
          'batch_size': requested,
        });
        expect(decoded.batchSize, 1);
      }
    });

    test('an absent cursor means "from the beginning"', () {
      final decoded = SyncPullRequest.fromJson({
        ...const SyncEnvelope().toJson(),
        'project_id': 'p',
        'device_id': 'd',
      });
      expect(decoded.cursor, 0);
    });

    // Task 10.64, finding J-4: `json['cursor'] as int?` and
    // `json['batch_size'] as int?` threw an uncaught `TypeError` on any
    // present-but-wrongly-typed value — every JSON type but int and null —
    // which `sync_routes.dart` had no chance to turn into a `400` because the
    // throw happened inside `SyncPushRequest`/`SyncPullRequest`/`SyncAckRequest
    // .fromJson` itself, downstream of the try/catch that only knows about
    // [SyncProtocolException]. It is one now.
    for (final MapEntry(key: label, value: badCursor) in <String, Object?>{
      'a string': 'abc',
      'a float': 1.5,
      'an object': {'a': 1},
      'a bool': true,
      'a list': [1],
    }.entries) {
      test('cursor as $label is a protocol error, not a crash', () {
        expect(
          () => SyncPullRequest.fromJson({
            ...const SyncEnvelope().toJson(),
            'project_id': 'p',
            'device_id': 'd',
            'cursor': badCursor,
          }),
          throwsA(isA<SyncProtocolException>()),
        );
      });
    }

    for (final MapEntry(key: label, value: badBatchSize) in <String, Object?>{
      'a string': 'abc',
      'a float': 1.5,
      'an object': {'a': 1},
      'a bool': true,
    }.entries) {
      test('batch_size as $label is a protocol error, not a crash', () {
        expect(
          () => SyncPullRequest.fromJson({
            ...const SyncEnvelope().toJson(),
            'project_id': 'p',
            'device_id': 'd',
            'batch_size': badBatchSize,
          }),
          throwsA(isA<SyncProtocolException>()),
        );
      });
    }
  });

  group('ack request', () {
    test('an absent cursor means "from the beginning"', () {
      final decoded = SyncAckRequest.fromJson({
        ...const SyncEnvelope().toJson(),
        'project_id': 'p',
        'device_id': 'd',
      });
      expect(decoded.cursor, 0);
    });

    // Same fix, same class, task 10.64: `SyncAckRequest.fromJson` shared the
    // unchecked `json['cursor'] as int?` [SyncPullRequest] had.
    test('a wrongly-typed cursor is a protocol error, not a crash', () {
      expect(
        () => SyncAckRequest.fromJson({
          ...const SyncEnvelope().toJson(),
          'project_id': 'p',
          'device_id': 'd',
          'cursor': 'abc',
        }),
        throwsA(isA<SyncProtocolException>()),
      );
    });
  });

  group('pull response', () {
    test('an empty page does not rewind the cursor', () {
      const response = SyncPullResponse(rows: {}, nextCursor: 42, remaining: 0);
      expect(response.nextCursor, 42);
      expect(response.hasMore, isFalse);
      expect(response.rowCount, 0);
    });

    test('remaining drives progress reporting for 10.12', () {
      const response = SyncPullResponse(
        rows: {},
        nextCursor: 10,
        remaining: 1500,
      );
      expect(response.hasMore, isTrue);
      expect(response.remaining, 1500);
    });

    test('round-trips through JSON', () {
      final response = SyncPullResponse(
        rows: {
          Tables.tags: [
            {'tag_id': 'tag-1'},
          ],
        },
        nextCursor: 7,
        remaining: 3,
      );
      final decoded = SyncPullResponse.fromJson(
        jsonDecode(jsonEncode(response.toJson())) as Map<String, Object?>,
      );
      expect(decoded.nextCursor, 7);
      expect(decoded.remaining, 3);
      expect(decoded.rows[Tables.tags]!.single['tag_id'], 'tag-1');
    });

    // Task 10.67: `next_cursor`/`remaining` used a naked `json[key] as int?`
    // — the exact shape task 10.64/J-4 fixed for the REQUEST side's
    // `cursor`/`batch_size` (via `optionalSyncInt`), left unfixed three
    // fields over on the response side. A wrong-typed field threw an
    // uncaught TypeError instead of the same SyncProtocolException every
    // other malformed field on this wire already draws.
    test('a wrongly-typed next_cursor is a protocol error, not a crash', () {
      expect(
        () => SyncPullResponse.fromJson({
          ...const SyncEnvelope().toJson(),
          'rows': <String, Object?>{},
          'next_cursor': 'not-a-number',
          'remaining': 0,
        }),
        throwsA(isA<SyncProtocolException>()),
      );
    });

    test('a wrongly-typed remaining is a protocol error, not a crash', () {
      expect(
        () => SyncPullResponse.fromJson({
          ...const SyncEnvelope().toJson(),
          'rows': <String, Object?>{},
          'next_cursor': 0,
          'remaining': {'not': 'a number'},
        }),
        throwsA(isA<SyncProtocolException>()),
      );
    });
  });

  group('push response', () {
    test('reports an outcome for every row, including losers', () {
      // Silence about a loss is the failure mode this field exists to prevent:
      // "my observation disappeared" is the bug that actually gets reported.
      final response = SyncPushResponse(
        applied: 1,
        outcomes: {
          'Observations/obs-1': SyncRowOutcome.updated,
          'Observations/obs-2': SyncRowOutcome.lostToServer,
        },
        highestServerSeq: 9,
      );
      expect(response.countOf(SyncRowOutcome.lostToServer), 1);
      expect(response.countOf(SyncRowOutcome.updated), 1);
    });

    test('every outcome survives a JSON round-trip', () {
      final response = SyncPushResponse(
        applied: 0,
        outcomes: {
          for (final outcome in SyncRowOutcome.values)
            'Observations/${outcome.db}': outcome,
        },
        highestServerSeq: null,
      );
      final decoded = SyncPushResponse.fromJson(
        jsonDecode(jsonEncode(response.toJson())) as Map<String, Object?>,
      );
      expect(decoded.outcomes.length, SyncRowOutcome.values.length);
      for (final outcome in SyncRowOutcome.values) {
        expect(decoded.outcomes['Observations/${outcome.db}'], outcome);
      }
    });

    // Task 10.67: `applied`/`highest_server_seq` were the same naked
    // `json[key] as int?` shape as `next_cursor`/`remaining` above.
    test('a wrongly-typed applied is a protocol error, not a crash', () {
      expect(
        () => SyncPushResponse.fromJson({
          ...const SyncEnvelope().toJson(),
          'applied': 'three',
          'outcomes': <String, Object?>{},
          'highest_server_seq': 9,
        }),
        throwsA(isA<SyncProtocolException>()),
      );
    });

    test(
      'a wrongly-typed highest_server_seq is a protocol error, not a crash',
      () {
        expect(
          () => SyncPushResponse.fromJson({
            ...const SyncEnvelope().toJson(),
            'applied': 1,
            'outcomes': <String, Object?>{},
            'highest_server_seq': [9],
          }),
          throwsA(isA<SyncProtocolException>()),
        );
      },
    );

    // Task 11.267 — the second channel a `RowRefusal` cannot answer: which
    // shared rule about the project's other rows refused the row.
    group('interlock refusals', () {
      test('survive a JSON round-trip', () {
        final response = SyncPushResponse(
          applied: 0,
          outcomes: {'Deployments/dep-1': SyncRowOutcome.invalid},
          interlockRefusals: {'Deployments/dep-1': DeploymentInterlock.ruleId},
          highestServerSeq: null,
        );
        final decoded = SyncPushResponse.fromJson(
          jsonDecode(jsonEncode(response.toJson())) as Map<String, Object?>,
        );
        expect(
          decoded.interlockRefusals['Deployments/dep-1'],
          DeploymentInterlock.ruleId,
        );
      });

      test('are dropped when they do not sit on an invalid outcome — the '
          'same security bound RowRefusal enforces', () {
        final response = SyncPushResponse(
          applied: 1,
          outcomes: {'Deployments/dep-1': SyncRowOutcome.updated},
          interlockRefusals: {'Deployments/dep-1': DeploymentInterlock.ruleId},
          highestServerSeq: 1,
        );
        expect(response.interlockRefusals, isEmpty);
      });

      test('omitted entirely from the wire when empty', () {
        final response = SyncPushResponse(
          applied: 0,
          outcomes: {'Deployments/dep-1': SyncRowOutcome.invalid},
          highestServerSeq: null,
        );
        expect(response.toJson().containsKey('interlock_refusals'), isFalse);
      });
    });
  });

  group('decodeRows', () {
    test('ignores unknown tables rather than failing', () {
      // Forward-compatible, matching BackupArchive.decode: a newer peer that
      // gained a table must not make an older one fail outright. Task 10.11
      // owns deliberate version refusal.
      final rows = decodeRows({
        Tables.observations: [
          {'observation_id': 'obs-1'},
        ],
        'Some_Future_Table': [
          {'x': 1},
        ],
      });
      expect(rows.keys, [Tables.observations]);
    });

    test('tolerates malformed shapes without throwing', () {
      expect(decodeRows(null), isEmpty);
      expect(decodeRows('nope'), isEmpty);
      expect(decodeRows({Tables.observations: 'not a list'}), isEmpty);
    });
  });

  group('unknown row outcome (finding L-8)', () {
    test('is a catchable protocol exception, not an Error', () {
      // The distinction is the whole finding: `Error` means "this program has
      // a bug" and nothing catches it, so the old `StateError` killed the app
      // rather than failing the sync.
      expect(
        () => SyncRowOutcome.fromDb('quarantined'),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(
        () => SyncRowOutcome.fromDb('quarantined'),
        isNot(throwsA(isA<Error>())),
      );
    });

    test(
      'a push response naming a future outcome fails the sync, not the app',
      () {
        // The deployed-fleet case: the server has grown a sixth outcome and this
        // client has not. It must come back as a sync that failed.
        final json = {
          'applied': 1,
          'outcomes': {'Observations|obs-1': 'quarantined'},
          'highest_server_seq': 7,
        };
        expect(
          () => SyncPushResponse.fromJson(json),
          throwsA(isA<SyncProtocolException>()),
        );
      },
    );
  });

  // Task 11.58. The identifier is what lets a device tell a restored or
  // rebuilt server from the one its bookmark and receipts were minted
  // against, so both of its compatibility directions are pinned here, where
  // the wire is.
  group('database identity (task 11.58)', () {
    Map<String, Object?> roundTrip(Map<String, Object?> json) =>
        jsonDecode(jsonEncode(json)) as Map<String, Object?>;

    test('a pull response carries it both ways', () {
      final json = roundTrip(
        const SyncPullResponse(
          rows: {},
          nextCursor: 0,
          remaining: 0,
          databaseId: '5b0e1c7a-9d7c-4f3e-8a55-0c1d2e3f4a5b',
        ).toJson(),
      );
      expect(json['database_id'], '5b0e1c7a-9d7c-4f3e-8a55-0c1d2e3f4a5b');
      expect(
        SyncPullResponse.fromJson(json).databaseId,
        '5b0e1c7a-9d7c-4f3e-8a55-0c1d2e3f4a5b',
      );
    });

    test('a push response carries it both ways', () {
      final json = roundTrip(
        SyncPushResponse(
          applied: 0,
          outcomes: const {},
          highestServerSeq: null,
          databaseId: 'db-1',
        ).toJson(),
      );
      expect(SyncPushResponse.fromJson(json).databaseId, 'db-1');
    });

    test('a server that predates it is read as "cannot say", not refused', () {
      // The newer-app-older-server direction of task 10.18: no field, no
      // failure, and null — which the app reads as "keep what you knew".
      final pull = roundTrip(
        const SyncPullResponse(rows: {}, nextCursor: 3, remaining: 0).toJson(),
      );
      expect(pull.containsKey('database_id'), isFalse);
      expect(SyncPullResponse.fromJson(pull).databaseId, isNull);
      final push = roundTrip(
        SyncPushResponse(
          applied: 0,
          outcomes: const {},
          highestServerSeq: null,
        ).toJson(),
      );
      expect(push.containsKey('database_id'), isFalse);
      expect(SyncPushResponse.fromJson(push).databaseId, isNull);
    });

    test('a value that is not a short token is a malformed response', () {
      final base = roundTrip(
        const SyncPullResponse(rows: {}, nextCursor: 0, remaining: 0).toJson(),
      );
      for (final bad in <Object>[
        7,
        '',
        'has spaces',
        'semi;colon',
        'x' * (maxSyncDatabaseIdLength + 1),
      ]) {
        expect(
          () => SyncPullResponse.fromJson({...base, 'database_id': bad}),
          throwsA(isA<SyncProtocolException>()),
          reason: 'database_id: ${jsonEncode(bad)}',
        );
      }
      // The longest acceptable value is accepted — the bound is the bound.
      expect(
        SyncPullResponse.fromJson({
          ...base,
          'database_id': 'x' * maxSyncDatabaseIdLength,
        }).databaseId,
        hasLength(maxSyncDatabaseIdLength),
      );
    });
  });
}

@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';

/// Task 10.17: serialization fidelity is checked first, because a
/// client/server mismatch on a timestamp, a null, or a numeric leaves both
/// existing suites green (the client's `FakeSyncTransport` tests and the
/// server's real-Postgres tests) while the product is broken — neither side
/// alone can see a disagreement about how the *wire* represents a value.
///
/// This talks to `HttpSyncTransport` directly rather than through
/// `SyncEngine`, deliberately: the engine hands pulled rows straight to
/// `ProjectMerger`, which reads through model-level `fromDb` coercions that
/// could paper over exactly the wire-level mismatch this test exists to
/// catch. Asserting on `SyncPullResponse.rows` — the raw decoded JSON map —
/// is the closest this suite gets to reading the wire itself.
void main() {
  group('serialization fidelity', skip: e2eSkipReason, () {
    late E2eDevice device;
    late String projectId;
    final now = DateTime.utc(2026, 8, 2, 9, 30, 15, 250);

    setUp(() async {
      device = await E2eDevice.create();
      await device.signIn(randomEmail());
      projectId = 'e2e-proj-${randomId()}';
      // Every push below is hand-crafted directly through the transport
      // rather than through `ProjectPublisher`, so nothing gathers this
      // device's `Users` row or creates the `Projects` row server-side the
      // way a real publish would — push both explicitly, or every row this
      // test pushes next fails Postgres's foreign key.
      await device.pushOwnUserAndProject(projectId: projectId, now: now);
      await seedLocalProject(
        device.db.raw,
        projectId: projectId,
        ownerId: device.userId,
        deviceId: device.deviceId,
        now: now,
      );
    });


    test('every column kind on Observations round-trips byte-identical', () async {
      final transport = device.transport();
      final sent =
          observationRow(
              'e2e-obs-${randomId()}',
              projectId: projectId,
              userId: device.userId,
              deviceId: device.deviceId,
              now: now,
            )
            // Overwrite the defaults with values chosen specifically to expose
            // wire-format drift: negative and positive doubles with several
            // decimal places (a naive float<->text conversion rounds these
            // differently on the two sides), an explicit null on an optional
            // real column, a populated optional real column near a bearing's
            // boundary, and a sub-second UTC timestamp (whole-second precision
            // is the easy case; a lossy `TIMESTAMP` column on the server would
            // truncate the milliseconds silently).
            ..['latitude'] = -34.603722
            ..['longitude'] = 138.700925
            ..['elevation'] = -12.375
            ..['altitude_agl'] = 0.0
            ..['position_accuracy_m'] = null
            ..['magnetic_bearing'] = 359.75
            ..['true_north_bearing'] = 0.25
            ..['bearing_uncertainty'] = null
            ..['tag_id'] = null
            ..['notes'] = null
            ..['created_at'] = DbCodec.encodeUtc(now)
            ..['updated_at'] = DbCodec.encodeUtc(now)
            ..['deleted_at'] = null
            ..['last_modified_by'] = device.userId
            ..['origin_device_id'] = device.deviceId;

      final pushResponse = await transport.push(
        SyncPushRequest(
          projectId: projectId,
          deviceId: device.deviceId,
          rows: {
            Tables.observations: [sent],
          },
        ),
      );
      expect(
        pushResponse.outcomes[
            '${Tables.observations}/${syncRowKey(syncTablesByName[Tables.observations]!, sent)}'],
        SyncRowOutcome.inserted,
      );

      final pullResponse = await transport.pull(
        SyncPullRequest(
          projectId: projectId,
          deviceId: '${device.deviceId}-other',
          cursor: 0,
          batchSize: defaultSyncBatchSize,
        ),
      );
      final received = (pullResponse.rows[Tables.observations] ?? const [])
          .firstWhere((r) => r['observation_id'] == sent['observation_id']);

      // Every domain column the sender set, compared value-for-value —
      // not merely "present", per the task's own wording. `server_seq`,
      // `received_at`, and `clock_skew_flag` are server-only bookkeeping
      // (never sent, never expected back) and are deliberately excluded.
      for (final entry in sent.entries) {
        expect(
          received[entry.key],
          entry.value,
          reason:
              'column "${entry.key}" did not round-trip: '
              'sent ${entry.value} (${entry.value.runtimeType}), '
              'received ${received[entry.key]} '
              '(${received[entry.key].runtimeType})',
        );
      }
    });

    test(
      'the six shared sync columns round-trip on every table kind',
      () async {
        // Observations (project-scoped, author-ruled) and Tags (global,
        // anyUser-ruled) exercise the two structurally different table shapes
        // in one pass — see `RowAuthorizer`'s doc comment for why they differ.
        final transport = device.transport();
        final tagId = 'e2e-tag-${randomId()}';
        final tagRow = {
          'tag_id': tagId,
          'frequency_mhz': 150.125,
          'pulse_rate': 60.0,
          'pulse_pattern': null,
          'tag_name': 'E2E Tag',
          'date_put_on': DbCodec.encodeUtc(now),
          'date_removed': null,
          'status': 'active',
          'color_hex': '#FF8800',
          'capture_date': null,
          'notes': null,
          'created_at': DbCodec.encodeUtc(now),
          'updated_at': DbCodec.encodeUtc(now),
          'deleted_at': null,
          'revision': 3,
          'last_modified_by': device.userId,
          'origin_device_id': device.deviceId,
        };

        await transport.push(
          SyncPushRequest(
            projectId: projectId,
            deviceId: device.deviceId,
            rows: {
              Tables.tags: [tagRow],
            },
          ),
        );
        // Link it into the project so a project-scoped pull is entitled to see
        // it — task 10.10's reachability rule, not this test's concern, but
        // required for the row to come back at all.
        await transport.push(
          SyncPushRequest(
            projectId: projectId,
            deviceId: device.deviceId,
            rows: {
              Tables.projectTags: [
                {
                  'project_id': projectId,
                  'tag_id': tagId,
                  'status': 'active',
                  'created_at': DbCodec.encodeUtc(now),
                  'updated_at': DbCodec.encodeUtc(now),
                  'deleted_at': null,
                  'revision': 0,
                  'last_modified_by': device.userId,
                  'origin_device_id': device.deviceId,
                },
              ],
            },
          ),
        );

        final pullResponse = await transport.pull(
          SyncPullRequest(
            projectId: projectId,
            deviceId: '${device.deviceId}-other',
            cursor: 0,
            batchSize: defaultSyncBatchSize,
          ),
        );
        final received = (pullResponse.rows[Tables.tags] ?? const [])
            .firstWhere((r) => r['tag_id'] == tagId);

        for (final entry in tagRow.entries) {
          expect(
            received[entry.key],
            entry.value,
            reason: 'Tags column "${entry.key}" did not round-trip',
          );
        }
      },
    );

    test(
      'an unauthenticated request is refused before any row is read',
      () async {
        final unauthenticated = HttpSyncTransport(
          httpClient: device.httpClient,
          baseUrl: E2eEnv.requireBaseUrl,
          sessionToken: 'not-a-real-session-token',
        );
        await expectLater(
          unauthenticated.pull(
            SyncPullRequest(
              projectId: projectId,
              deviceId: device.deviceId,
              cursor: 0,
              batchSize: defaultSyncBatchSize,
            ),
          ),
          throwsA(
            isA<SyncTransportException>().having(
              (e) => e.statusCode,
              'statusCode',
              401,
            ),
          ),
        );
      },
    );
  });
}

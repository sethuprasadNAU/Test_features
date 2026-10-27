@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';

/// Task 10.18, against a live server: an app a schema **minor** behind still
/// syncs, and one on a different **major** is refused with the right side named.
///
/// The unit suites prove the client half — that an unrecognized value is held
/// and returned byte-identical (`test/data/sync/schema_compatibility_test.dart`)
/// and that the envelope decides compatibility on the major
/// (`packages/tritrack_sync/test/version_skew_test.dart`). What only a real
/// server can answer is whether that agreement actually holds across the socket:
/// the check lives in a shared `SyncEnvelope.fromJson`, and a server that
/// validated somewhere else, or that reported the two sides the wrong way round
/// in its 409 body, would still pass every test on either side alone.
///
/// The skew is injected by handing the request DTOs an envelope with a doctored
/// version, which is exactly what a device running an older build would send.
void main() {
  group('schema compatibility over real HTTP', skip: e2eSkipReason, () {
    late E2eDevice device;
    late String projectId;
    late DateTime now;

    setUp(() async {
      device = await E2eDevice.create();
      await device.signIn(randomEmail());
      now = DateTime.now().toUtc();
      projectId = 'e2e-proj-${randomId()}';
      await seedLocalProject(
        device.db.raw,
        projectId: projectId,
        ownerId: device.userId,
        deviceId: device.deviceId,
        now: now,
      );
      // The project has to exist *on the server* before these tests can pull
      // it. It did not used to: a pull for a project the server had never seen
      // answered 200-empty, which was Gate C's C-2 existence oracle, and this
      // setUp was quietly depending on it. Publishing first is what a device
      // syncing a project has always actually done — and version skew is the
      // subject here, not project access.
      await device.pushOwnUserAndProject(projectId: projectId, now: now);
    });


    test('a client one MINOR behind the server syncs normally', () async {
      // Standing rule 5 upgrades the server first, so this is the *normal*
      // state of a fleet during a rollout, not an edge case. Under 10.11's
      // exact-equality policy every device in the field stopped syncing here
      // until it updated — which, in a season with poor connectivity, could be
      // weeks of observations stranded on phones.
      final response = await device.transport().pull(
        SyncPullRequest(
          projectId: projectId,
          deviceId: device.deviceId,
          cursor: 0,
          batchSize: defaultSyncBatchSize,
          envelope: SyncEnvelope(schemaVersion: latestSchemaVersion - 1),
        ),
      );

      expect(response.nextCursor, greaterThanOrEqualTo(0));
      // The server answers with its own version, not an echo of ours.
      expect(response.envelope.schemaVersion, latestSchemaVersion);
      expect(response.envelope.schemaMajor, schemaMajorVersion);
    });

    test('a client one MINOR ahead of the server syncs too', () async {
      // The mirrored direction. It should not arise if releases follow rule 5,
      // but a rule is not a mechanism, and a refusal here would be just as
      // damaging as the one above.
      final response = await device.transport().pull(
        SyncPullRequest(
          projectId: projectId,
          deviceId: device.deviceId,
          cursor: 0,
          batchSize: defaultSyncBatchSize,
          envelope: SyncEnvelope(schemaVersion: latestSchemaVersion + 1),
        ),
      );

      expect(response.envelope.schemaMajor, schemaMajorVersion);
    });

    test('a client on a newer MAJOR is refused, and told the server is behind',
        () async {
      // Naming the wrong side is the failure that actually costs someone a
      // day: a field tech told to update an app that is already current, while
      // the server is the stale one, has no way to discover the real problem.
      try {
        await device.transport().pull(
          SyncPullRequest(
            projectId: projectId,
            deviceId: device.deviceId,
            cursor: 0,
            batchSize: defaultSyncBatchSize,
            envelope: SyncEnvelope(schemaMajor: schemaMajorVersion + 1),
          ),
        );
        fail('expected the server to refuse a major-version mismatch');
      } on SyncTransportException catch (error) {
        expect(error.reason, syncRefusalSchemaVersion);
        expect(error.isTerminal, isTrue);
        expect(error.appIsBehindServer, isFalse);
        expect(error.userMessage, contains('server'));
        expect(error.detail['client_schema_major'], schemaMajorVersion + 1);
        expect(error.detail['server_schema_major'], schemaMajorVersion);
      }
    });

    test('a client on an older MAJOR is refused, and told to update the app',
        () async {
      try {
        await device.transport().pull(
          SyncPullRequest(
            projectId: projectId,
            deviceId: device.deviceId,
            cursor: 0,
            batchSize: defaultSyncBatchSize,
            envelope: SyncEnvelope(schemaMajor: schemaMajorVersion - 1),
          ),
        );
        fail('expected the server to refuse a major-version mismatch');
      } on SyncTransportException catch (error) {
        expect(error.reason, syncRefusalSchemaVersion);
        expect(error.appIsBehindServer, isTrue);
        expect(error.userMessage, contains('Update the app'));
      }
    });

    test(
        'schema major 1 specifically — every pre-10.35 build — is refused by a '
        'real server', () async {
      // **The first real use of 10.18's major-version refusal**, and the reason
      // task 10.35's acceptance criteria call for exercising it deliberately.
      //
      // The two tests above are written relative to `schemaMajorVersion`, so
      // they held before this bump and would hold after any future one. This
      // one is absolute on purpose: `1` is not an arbitrary older number, it is
      // the version every build that existed before project-scoped keys speaks,
      // and it is the version whose rows this server can no longer interpret —
      // an `Observations` row from a major-1 client carries a key the server
      // would resolve to the wrong shape entirely.
      //
      // It is pinned as a literal rather than derived so that a *second* major
      // bump does not silently retarget it at major 2 and stop covering this.
      try {
        await device.transport().pull(
          SyncPullRequest(
            projectId: projectId,
            deviceId: device.deviceId,
            cursor: 0,
            batchSize: defaultSyncBatchSize,
            envelope: const SyncEnvelope(schemaMajor: 1),
          ),
        );
        fail('expected a real server to refuse schema major 1');
      } on SyncTransportException catch (error) {
        expect(error.reason, syncRefusalSchemaVersion);
        expect(error.detail['client_schema_major'], 1);
        expect(error.detail['server_schema_major'], schemaMajorVersion);
        // Terminal, not retryable: the scheduler must stop rather than back off
        // and try again forever. A refusal the app keeps retrying is a battery
        // drain in the field and, worse, looks like a network problem.
        expect(error.isTerminal, isTrue);
        expect(error.appIsBehindServer, isTrue);
        expect(error.userMessage, contains('Update the app'));
      }
    });

    test('a major-1 push is refused before it can write anything', () async {
      // The refusal has to be *ahead* of the write, not merely reported after
      // it. A major-1 client's `Observations` row is keyed differently, so a
      // server that refused only on the way out would already have stored a row
      // under a key it derived wrongly. `SyncEnvelope.fromJson` runs while the
      // request is still being decoded, which is what makes this hold — but
      // that is a property worth pinning rather than inferring.
      try {
        await device.transport().push(
          SyncPushRequest(
            projectId: projectId,
            deviceId: device.deviceId,
            rows: {
              Tables.observations: [
                {'observation_id': 'obs-major-1', 'project_id': projectId},
              ],
            },
            envelope: const SyncEnvelope(schemaMajor: 1),
          ),
        );
        fail('expected a real server to refuse a major-1 push');
      } on SyncTransportException catch (error) {
        expect(error.reason, syncRefusalSchemaVersion);
        expect(error.isTerminal, isTrue);
      }

      // Nothing was written: a subsequent well-formed pull does not see it.
      final response = await device.transport().pull(
        SyncPullRequest(
          projectId: projectId,
          deviceId: device.deviceId,
          cursor: 0,
          batchSize: defaultSyncBatchSize,
        ),
      );
      final observations = response.rows[Tables.observations] ?? const [];
      expect(
        observations.where((r) => r['observation_id'] == 'obs-major-1'),
        isEmpty,
        reason: 'a refused major-1 push must not have stored a row',
      );
    });
  });
}

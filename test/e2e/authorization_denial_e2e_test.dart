@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';

/// Task 10.17: task 10.10's authorization boundary, checked against a real
/// server rather than a `RowAuthorizer` constructed directly inside the
/// server's own process — the same client request path a hostile or
/// merely-buggy app build would actually make.
void main() {
  group(
    'authorization is enforced by the server, not the client',
    skip: e2eSkipReason,
    () {
      late E2eDevice owner;
      late E2eDevice stranger;
      late String projectId;
      final now = DateTime.utc(2026, 8, 2, 13);

      setUp(() async {
        owner = await E2eDevice.create();
        await owner.signIn(randomEmail());
        stranger = await E2eDevice.create();
        await stranger.signIn(randomEmail());

        projectId = 'e2e-proj-${randomId()}';
        // Published via a real push so it genuinely exists server-side —
        // otherwise the "project not yet published" case would (correctly)
        // let anyone's first push through, which is not what this test means
        // to exercise.
        await owner.pushOwnUserAndProject(projectId: projectId, now: now);
      });

      // See `E2eDevice.create`: each device registers its own tear-down.

      test('a stranger cannot push to a project they do not own', () async {
        // A caller with zero relationship to the project is refused at the
        // *project* boundary (`ProjectAuthorizer`) before a single row is
        // even looked at — a 403 with no `SyncPushResponse` body at all, not
        // a 200 carrying a per-row `unauthorized` outcome. That distinction
        // (project-level vs. row-level denial) is task 10.10's own design;
        // see `RowAuthorizer`'s doc comment for why both checks exist.
        await expectLater(
          stranger.transport().push(
            SyncPushRequest(
              projectId: projectId,
              deviceId: stranger.deviceId,
              rows: {
                Tables.observations: [
                  observationRow(
                    'e2e-obs-${randomId()}',
                    projectId: projectId,
                    userId: stranger.userId,
                    deviceId: stranger.deviceId,
                    now: now,
                  ),
                ],
              },
            ),
          ),
          throwsA(
            isA<SyncTransportException>().having(
              (e) => e.statusCode,
              'statusCode',
              403,
            ),
          ),
        );

        // Refused, not silently accepted-and-ignored: nothing this stranger
        // sent reaches the server's copy of the project.
        final page = await owner.transport().pull(
          SyncPullRequest(
            projectId: projectId,
            deviceId: '${owner.deviceId}-verify',
            cursor: 0,
            batchSize: defaultSyncBatchSize,
          ),
        );
        expect(page.rows[Tables.observations], isNull);
      });

      test('a stranger cannot pull a project they do not belong to', () async {
        await expectLater(
          stranger.transport().pull(
            SyncPullRequest(
              projectId: projectId,
              deviceId: stranger.deviceId,
              cursor: 0,
              batchSize: defaultSyncBatchSize,
            ),
          ),
          throwsA(
            isA<SyncTransportException>().having(
              (e) => e.statusCode,
              'statusCode',
              403,
            ),
          ),
        );
      });

      test(
        "a stranger's push cannot overwrite a row the owner already has",
        () async {
          final observationId = 'e2e-obs-owner-${randomId()}';
          await owner.transport().push(
            SyncPushRequest(
              projectId: projectId,
              deviceId: owner.deviceId,
              rows: {
                Tables.observations: [
                  observationRow(
                    observationId,
                    projectId: projectId,
                    userId: owner.userId,
                    deviceId: owner.deviceId,
                    now: now,
                  ),
                ],
              },
            ),
          );

          await expectLater(
            stranger.transport().push(
              SyncPushRequest(
                projectId: projectId,
                deviceId: stranger.deviceId,
                rows: {
                  Tables.observations: [
                    observationRow(
                      observationId,
                      projectId: projectId,
                      userId: owner.userId,
                      deviceId: stranger.deviceId,
                      now: now.add(const Duration(minutes: 5)),
                      revision: 99,
                      notes: 'forged',
                    ),
                  ],
                },
              ),
            ),
            throwsA(
              isA<SyncTransportException>().having(
                (e) => e.statusCode,
                'statusCode',
                403,
              ),
            ),
          );

          // Refused, not silently accepted-and-ignored: pulled straight back
          // from the server (not the owner's untouched local copy, which
          // proves nothing about what the server actually stored).
          final page = await owner.transport().pull(
            SyncPullRequest(
              projectId: projectId,
              deviceId: '${owner.deviceId}-verify',
              cursor: 0,
              batchSize: defaultSyncBatchSize,
            ),
          );
          final onServer = (page.rows[Tables.observations] ?? const [])
              .firstWhere((r) => r['observation_id'] == observationId);
          expect(onServer['notes'], isNot('forged'));
        },
      );
    },
  );
}

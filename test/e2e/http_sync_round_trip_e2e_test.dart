@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';

/// A [SyncTransport] that delegates to a real one but throws after a
/// configured number of `pull` calls — a real, connected server for
/// everything up to the interruption, then a dropped connection, exactly
/// like a device losing signal mid-sync.
class _FlakyTransport implements SyncTransport {
  _FlakyTransport(this._inner, {this.failPullAfter});

  final SyncTransport _inner;
  final int? failPullAfter;
  int _pulls = 0;

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) async {
    if (failPullAfter != null && _pulls >= failPullAfter!) {
      throw const SyncTransportException('unreachable');
    }
    _pulls++;
    return _inner.pull(request);
  }

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) =>
      _inner.push(request);

  @override
  Future<void> ack(SyncAckRequest request) => _inner.ack(request);

  @override
  Future<List<ProjectSummary>> listMyProjects() => _inner.listMyProjects();

  @override
  Future<List<DeletedProjectSummary>> listMyDeletedProjects() =>
      _inner.listMyDeletedProjects();

  // Task 11.2's invite surface. Delegated rather than stubbed: this wrapper
  // exists to drop a *pull* mid-stream, and anything it intercepted beyond
  // that would be modelling the server rather than the dead zone.
  @override
  Future<JoinSettings> joinSettings(String projectId) =>
      _inner.joinSettings(projectId);

  @override
  Future<JoinSettings> updateJoinSettings({
    required String projectId,
    bool? joiningEnabled,
    int? teamSizeLimit,
  }) => _inner.updateJoinSettings(
    projectId: projectId,
    joiningEnabled: joiningEnabled,
    teamSizeLimit: teamSizeLimit,
  );

  @override
  Future<RotateJoinCodeResponse> rotateJoinCode({
    required String projectId,
    bool clearPending = false,
  }) => _inner.rotateJoinCode(
    projectId: projectId,
    clearPending: clearPending,
  );

  @override
  Future<List<JoinRequestSummary>> joinRequests(String projectId) =>
      _inner.joinRequests(projectId);

  @override
  Future<void> approveJoinRequest({
    required String projectId,
    required String requestId,
    required ProjectRole role,
  }) => _inner.approveJoinRequest(
    projectId: projectId,
    requestId: requestId,
    role: role,
  );

  @override
  Future<void> rejectJoinRequest({
    required String projectId,
    required String requestId,
  }) => _inner.rejectJoinRequest(projectId: projectId, requestId: requestId);

  @override
  Future<void> readmitMember({
    required String projectId,
    required String userId,
    required ProjectRole role,
  }) => _inner.readmitMember(
    projectId: projectId,
    userId: userId,
    role: role,
  );

  @override
  Future<JoinRequestCreatedResponse> requestToJoin({
    required String code,
    String? claimedName,
  }) => _inner.requestToJoin(code: code, claimedName: claimedName);

  @override
  Future<List<MyJoinRequest>> myJoinRequests() => _inner.myJoinRequests();

  @override
  Future<ProjectDeletionStanding> projectDeletion(String projectId) =>
      _inner.projectDeletion(projectId);

  @override
  Future<ProjectDeletionStanding> setProjectDeletion(
    String projectId,
    ProjectDeletionAction action,
  ) => _inner.setProjectDeletion(projectId, action);
}

/// Task 10.17: `SyncEngine` — full coverage against `FakeSyncTransport` per
/// task 10.8 — has never pushed or pulled a single row over a real socket.
/// This drives it against `HttpSyncTransport` and a live server instead,
/// while leaving 10.8's fake-transport suite completely untouched (this
/// file is additive, per the task's explicit instruction).
void main() {
  group('HttpSyncTransport + SyncEngine over real HTTP', skip: e2eSkipReason, () {
    late E2eDevice device;
    late String email;
    late String projectId;
    late DateTime now;

    setUp(() async {
      device = await E2eDevice.create();
      email = randomEmail();
      await device.signIn(email);
      // Captured *after* signing in, so rows written below are dated after the
      // `Users` row sign-in stamps with the real wall-clock time. This used to
      // be load-bearing: a fixed historical `now` sat *before* the push
      // watermark that first row set, and `updated_at >= watermark` then never
      // offered those rows again. Task 10.33 removed the watermark — selection
      // is now "what the server has not confirmed", so an older row is offered
      // like any other — and this is kept only because chronological test data
      // reads better than data from before the account existed.
      now = DateTime.now().toUtc();
      projectId = 'e2e-proj-${randomId()}';
      await seedLocalProject(
        device.db.raw,
        projectId: projectId,
        ownerId: device.userId,
        deviceId: device.deviceId,
        now: now,
      );
    });


    SyncEngine engineFor(E2eDevice d, {SyncTransport? transport}) => SyncEngine(
      db: d.db.raw,
      transport: transport ?? d.transport(),
      state: d.state,
      deviceId: d.deviceId,
      userId: d.userId,
    );

    test(
      'a full push-then-pull round trip merges through ProjectMerger',
      () async {
        await device.db.raw.insert(
          Tables.observations,
          observationRow(
            'e2e-obs-${randomId()}',
            projectId: projectId,
            userId: device.userId,
            deviceId: device.deviceId,
            now: now,
          ),
        );

        final report = await engineFor(device).run(projectId);

        expect(report.pushed, greaterThan(0));
        expect(report.applied, greaterThan(0));
        expect(report.lostToServer, isEmpty);
      },
    );

    test(
      'an interrupted pull resumes without loss and without skipping rows',
      () async {
        // Settle this device's own Users/Projects/Project_Memberships rows
        // first — pushed and, from a second device's point of view, already
        // pulled — so the interruption below has nothing to land on except
        // the five observations that are this test's actual subject.
        await engineFor(device).run(projectId);

        // A second device belonging to the *same* person — signing in with
        // the same address the server already knows converges on the same
        // `user_id` (task 10.6), which is what makes this project reachable
        // from a device that has never seen it before. Settled with one clean
        // sync of its own, before the observations exist, for the same reason.
        final joiner = await E2eDevice.create();
        addTearDown(joiner.close);
        await joiner.signIn(email);
        expect(joiner.userId, device.userId);
        await engineFor(joiner).run(projectId);

        // Five rows, pulled one page at a time on the joining device, so a
        // mid-stream failure there has somewhere real to interrupt.
        for (var i = 0; i < 5; i++) {
          await device.db.raw.insert(
            Tables.observations,
            observationRow(
              'e2e-obs-$i-${randomId()}',
              projectId: projectId,
              userId: device.userId,
              deviceId: device.deviceId,
              now: now,
            ),
          );
        }
        // Pushed with the default batch size, so all five observations reach
        // the server in one round. A small `batchSize` would merely take
        // several rounds now rather than silently truncate — task 10.33 made a
        // row the limit never reached stay pending instead of being stranded
        // below a watermark — but the interruption below is entirely about the
        // *pull* side, and one push keeps that isolated.
        await engineFor(device).run(projectId);

        final flaky = _FlakyTransport(joiner.transport(), failPullAfter: 1);

        await expectLater(
          engineFor(joiner, transport: flaky).run(projectId, batchSize: 1),
          throwsA(isA<SyncTransportException>()),
        );

        final cursorAfterFailure = await joiner.state.cursor(projectId);
        final rowsAfterFailure = await joiner.db.raw.query(
          Tables.observations,
          where: 'project_id = ?',
          whereArgs: [projectId],
        );
        // Exactly one page committed before the interruption — not zero
        // (the failure must not roll back a page that already landed) and
        // not more than one (the failure must actually have interrupted).
        expect(rowsAfterFailure, hasLength(1));
        expect(cursorAfterFailure, greaterThan(0));

        // Resume with a transport that no longer fails — the real acceptance
        // criterion: the retry picks up from the stored cursor, not from zero,
        // and every remaining row arrives with nothing duplicated.
        await engineFor(joiner).run(projectId, batchSize: 1);

        final rowsAfterResume = await joiner.db.raw.query(
          Tables.observations,
          where: 'project_id = ?',
          whereArgs: [projectId],
        );
        expect(rowsAfterResume, hasLength(5));
        expect(
          rowsAfterResume.map((r) => r['observation_id']).toSet(),
          hasLength(5),
          reason: 'no duplicate rows after resuming',
        );
      },
    );
  });
}

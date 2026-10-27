import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/errors/transport_failure.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/widgets/sync_status_presentation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **What the sync surface says, driven by what a server did** (task 11.97).
///
/// **Task 11.189 replaced the surface and left this file's subject intact.**
/// What used to be a coloured strip above every tab is now one icon on the
/// map and a dot on the More tab, and the sentence each state produces moved
/// into `SyncStatusPresentation`. Every state below is still reached by a
/// real round against a real server, and still read as words rather than as
/// an enum; what changed is that this file no longer has to mount a widget to
/// see them. The names below say "the bar" where the history does.
///
/// ## The hole this fills
///
/// Every other test of this surface starts halfway along. The engine's own
/// suite drives `SyncEngine` directly and never sees a server round-trip; the
/// presentation's own tests hand it a `SyncStatus` built by hand and never see
/// a server. **Nothing joined the two**, because `SyncController` built
/// its own `HttpSyncTransport` — so a round could not be pointed at anything
/// but a real network, and the four states `/w-05` named — *offline*, *records
/// refused*, *records missing*, and *you are no longer on this project* — were
/// drawn by the app, explained by the app, and reachable only by a person with
/// a phone.
///
/// That is not a coverage statistic. **Tasks 11.54 and 11.60 exist because two
/// of those states were wrong in ways only somebody on real hardware found**,
/// and these are the states a field tech reads to decide whether their day's
/// records are safe.
///
/// ## Every state this surface can draw, and where it is now driven from
///
/// | what the surface says | driven by |
/// |---|---|
/// | `Syncing…` | here — a server held open mid-push |
/// | `Synced …` | here — a clean round |
/// | `Offline — last synced …` | here — one failed round |
/// | `Sync isn't working` | here — three failed rounds |
/// | `N records aren't on the server` | here — a server refusing a row |
/// | `N records the server sent could not be read` | here — a row this build's validator rejects |
/// | `You're no longer on this project` | here — a closed membership arriving in a `200` |
/// | `The server is refusing access` | here — a bare `403` |
/// | `Signed out` | here — a `401` |
/// | `Sync needs an update` | here — a schema-version refusal |
/// | `…doesn't trust the server's security certificate` | here — a certificate refusal |
/// | `Not a network problem — …refuses the server address` | `server_address_refused_test.dart` |
/// | `Not synced in N days …` | `sync_provider_test.dart` |
/// | hidden entirely | `sync_bar_through_the_cycle_test.dart` |
///
/// **The last three are not driven from here, and the reason is not an
/// omission.** A refused address is settled before any connection is built —
/// no server, failing or otherwise, is consulted — and staleness is a fact
/// about a clock rather than about a server, so a substituted server has
/// nothing to say about either. Naming them here is what keeps this table
/// readable as *the whole set* rather than as the set somebody got around to.
///
/// ## The shape of every test here
///
/// Seed a server, sync, read the words. Nothing constructs a `SyncStatus`, and
/// nothing asserts an enum without also asserting the sentence a person reads
/// — an enum can be right while the sentence under it is the one that sent
/// somebody outside looking for signal, which is exactly what happened twice.
///
/// ## Watched red first, and what the red said
///
/// Every test here was run against the pre-change engine — the one that built
/// its own connection — by temporarily restoring it. **Nine of the eleven
/// failed, and all nine failed the same way: `SyncHealth.offline`.** That is
/// the finding in one line. With the engine building its own connection, the
/// substituted server was not a failing server, it was *no server*, so the
/// only two states this file could reach were the two that describe a request
/// that never arrived — offline, and broken. Those two are exactly the two
/// that stayed green, and they were green for the wrong reason.
void main() {
  setUp(installFakeSharedPreferences);

  late AppDatabase db;
  late FakeSyncTransport server;

  const projectId = 'proj-1';
  const userId = 'user-1';
  const ownerId = 'owner-2';
  final now = DateTime.utc(2026, 9, 1, 9);
  final stamp = DbCodec.encodeUtc(now);

  Future<void> seedLocalProject({bool membershipOpen = true}) async {
    for (final (id, name) in [(userId, 'Sam'), (ownerId, 'Ada')]) {
      await db.raw.insert(Tables.users, {
        'user_id': id,
        'first_name': name,
        'last_name': 'Ranger',
        'email': '$id@example.com',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': id,
        'origin_device_id': 'device-A',
      });
    }
    await db.raw.insert(Tables.projects, {
      'project_id': projectId,
      'project_name': 'Elk',
      'owner_user_id': ownerId,
      'creation_date': stamp,
      'datum': 'WGS84',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': ownerId,
      'origin_device_id': 'device-B',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    });
    await db.raw.insert(Tables.projectMemberships, {
      'membership_id': 'mem-1',
      'project_id': projectId,
      'user_id': userId,
      'join_date': stamp,
      'end_date': membershipOpen ? null : stamp,
      'role': 'contributor',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': membershipOpen ? 0 : 1,
      'last_modified_by': userId,
      'origin_device_id': 'device-A',
    });
  }

  setUp(() async {
    db = await AppDatabase.openInMemory();
    server = FakeSyncTransport()
      ..sessionUserId = userId
      ..sessionEmail = 'sam@example.com';
    // **Seeded here rather than in a test body, and that is a constraint
    // rather than a style.** A `testWidgets` body runs on a fake clock, and
    // awaiting anything that reaches SQLite inside one leaves the clock's
    // pump loop dead — every later `pumpWidget` then hangs, with no output, to
    // the ten-minute timeout. `setUp` runs before that clock is installed.
    // Anything a single test needs on top of this goes in [syncAndRead]'s
    // `before`, which runs inside `runAsync`.
    await seedLocalProject();
  });
  tearDown(() => db.close());

  /// A signed-in device whose **only** way to a server is [server].
  ///
  /// One override, and it reaches the sync engine, the membership surface and
  /// the join controller alike — which is the whole of the seam this task
  /// added. Before it, this line could not be written.
  ProviderContainer syncingContainer() => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) async => db),
      serverTransportProvider.overrideWith((ref) async => server),
      currentUserProvider.overrideWith(
        (ref) async => User(
          userId: userId,
          firstName: 'Sam',
          lastName: 'Ranger',
          email: 'sam@example.com',
          sync: SyncMeta.initial(now: now),
        ),
      ),
      sessionStoreProvider.overrideWithValue(
        FakeSessionStore(
          StoredSession(
            token: 'not-a-real-token',
            userId: userId,
            email: 'sam@example.com',
            expiresAt: DateTime.now().add(const Duration(days: 30)),
          ),
        ),
      ),
    ],
  );

  Map<String, Object?> observation(
    String id, {
    String signalStrength = 'strong',
  }) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'timestamp_local': stamp,
    'timestamp_utc': stamp,
    'timezone_offset': '+00:00',
    'latitude': 43.2,
    'longitude': -117.1,
    'position_source': 'gps_fix',
    'elevation': 1400.0,
    'altitude_agl': 1.5,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': signalStrength,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };

  /// Puts the device in the ordinary syncing state: an address, an open
  /// project, and a project this device has published.
  Future<void> activate(ProviderContainer container) async {
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://tritrack.example.org');
    await container.read(activeProjectIdProvider.notifier).set(projectId);
    await container.read(syncStateStoreProvider).markProjectLinked(projectId);
    await container.read(syncControllerProvider.future);
  }

  /// **Runs a real round, and hands back the status it produced.**
  ///
  /// ## Why the round happens inside [WidgetTester.runAsync]
  ///
  /// A round reaches SQLite, which answers from a background isolate, and a
  /// `testWidgets` body otherwise runs on a fake clock where that answer never
  /// arrives. Measured while writing this file: without `runAsync` the test
  /// produced no output at all for ten minutes and then timed out — a hang,
  /// not a failure, which is the worst way for a test to be wrong.
  Future<SyncStatus> syncAndRead(
    WidgetTester tester,
    ProviderContainer container, {
    int rounds = 1,
    Future<void> Function()? before,
  }) async {
    final status = await tester.runAsync(() async {
      await before?.call();
      await activate(container);
      for (var i = 0; i < rounds; i++) {
        await container.read(syncControllerProvider.notifier).syncNow();
      }
      return container.read(syncControllerProvider).requireValue;
    });
    return status!;
  }

  /// **The sentence a person reads, for exactly the status a round
  /// produced.**
  ///
  /// ## Why this is not a widget any more
  ///
  /// Until task 11.189 this file pumped `SyncStatusBanner` — the strip above
  /// every tab — in a second `ProviderContainer`, because mounting a
  /// database-backed one inside a `testWidgets` body **hangs `pumpWidget`
  /// outright** (the fake-clock collision described on [syncAndRead]). The
  /// strip is gone; the sentence lives in `SyncStatusPresentation`, which is
  /// a plain class over a `SyncStatus` and needs no container and no widget.
  ///
  /// **Nothing about what this file checks changed.** What crosses this line
  /// is still the app's own [SyncStatus] produced by a real round against a
  /// real server, not a fixture: nothing here chooses `heldCount` or a
  /// failure cause, the round did. The surfaces that draw this — the status
  /// icon on the map and the More tab's badge — are covered in
  /// `sync_status_icon_test.dart`.
  String saidBy(SyncStatus status) => SyncStatusPresentation.of(status).message;

  SyncSeverity severityOf(SyncStatus status) =>
      SyncStatusPresentation.of(status).severity;

  group('a server that works', () {
    testWidgets('a clean round reports what it did, in the bar', (
      tester,
    ) async {
      final container = syncingContainer();
      addTearDown(container.dispose);

      final status = await syncAndRead(tester, container);

      expect(status.health, SyncHealth.healthy);
      expect(saidBy(status), contains('Synced'));
      expect(severityOf(status), SyncSeverity.healthy);
      // The round really happened rather than being short-circuited — this is
      // the assertion that would catch a seam that was installed and then not
      // reached.
      expect(server.pushCalls, greaterThan(0));
      expect(server.pullCalls, greaterThan(0));
    });
  });

  group('a server that cannot be reached', () {
    testWidgets('one failed round is offline, and does not shout', (
      tester,
    ) async {
      final container = syncingContainer();
      addTearDown(container.dispose);
      server.failNextCalls = 1;

      final status = await syncAndRead(tester, container);

      expect(status.health, SyncHealth.offline);
      // The words matter more than the enum: a dead zone is the normal field
      // condition, and a bar that called it a fault would train people to
      // ignore it (task 10.12).
      expect(saidBy(status), contains('Offline'));
      expect(saidBy(status), isNot(contains("isn't working")));
      // And quiet, not amber: being out of signal is the normal field
      // condition and an alarm for it would train people to ignore this.
      expect(severityOf(status), SyncSeverity.quiet);
    });

    testWidgets('three failed rounds is broken, and says so', (tester) async {
      final container = syncingContainer();
      addTearDown(container.dispose);
      server.permanentFailure = const SyncTransportException(
        SyncTransportException.unreachable,
      );

      final status = await syncAndRead(tester, container, rounds: 3);

      expect(status.health, SyncHealth.broken);
      expect(saidBy(status), "Sync isn't working. Tap to check.");
    });
  });

  group('a server that refuses a record (finding D-3, task 10.28)', () {
    testWidgets('the refusal is counted and the bar never says synced', (
      tester,
    ) async {
      final container = syncingContainer();
      addTearDown(container.dispose);
      server.refuseRows['${Tables.observations}/obs-refused/$projectId'] =
          SyncRowOutcome.unauthorized;

      final status = await syncAndRead(
        tester,
        container,
        before: () =>
            db.raw.insert(Tables.observations, observation('obs-refused')),
      );

      expect(status.health, SyncHealth.rowsRefused);
      expect(status.heldCount, 1);
      // The exact defect: a refused record and a calm green "Synced."
      expect(saidBy(status), isNot(contains('Synced')));
      expect(saidBy(status), "1 record isn't on the server. Tap to see why.");
      expect(severityOf(status), SyncSeverity.fault);
    });
  });

  group('a server sending a record this build cannot read (task 11.41)', () {
    testWidgets('the missing record is counted and named in the bar', (
      tester,
    ) async {
      final container = syncingContainer();
      addTearDown(container.dispose);
      // The likeliest real cause: a teammate on a newer build sends an enum
      // value this one has never heard of.
      server.seedServerRow(
        Tables.observations,
        observation('obs-future', signalStrength: 'blisteringly_loud'),
      );

      final status = await syncAndRead(tester, container);

      expect(status.health, SyncHealth.recordsMissing);
      expect(status.droppedOnArrivalCount, 1);
      expect(
        saidBy(status),
        '1 record the server sent could not be read by this app. '
        'Tap to see why.',
      );
      // Amber rather than red: nothing is lost. The record is safe on the
      // server and on whoever wrote it; this device simply does not have it.
      expect(severityOf(status), SyncSeverity.warning);
    });
  });

  group('a project the person is no longer on (tasks 11.54, 11.60)', () {
    testWidgets('the news arrives in a successful round, and the bar is calm', (
      tester,
    ) async {
      final container = syncingContainer();
      addTearDown(container.dispose);
      // What an owner's removal looks like from here: the membership row comes
      // back closed, in a `200`, on the pull.
      server.closedMembershipProjects.add(projectId);
      server.seedServerRow(Tables.projectMemberships, {
        'membership_id': 'mem-1',
        'project_id': projectId,
        'user_id': userId,
        'join_date': stamp,
        'end_date': stamp,
        'role': 'contributor',
        'created_at': stamp,
        'updated_at': DbCodec.encodeUtc(now.add(const Duration(hours: 1))),
        'revision': 1,
        'last_modified_by': ownerId,
        'origin_device_id': 'device-B',
      });

      final status = await syncAndRead(tester, container);

      expect(status.health, SyncHealth.membershipEnded);
      expect(saidBy(status), contains("You're no longer on this project"));
      // **Not red, and not an error.** Being removed is somebody else's
      // decision about this person, not a fault of the app — the single most
      // misleading thing this surface did (task 11.54). The icon is grey with
      // a door-out glyph, which is neither the green tick nor an alarm.
      expect(severityOf(status), SyncSeverity.quiet);
      expect(SyncStatusPresentation.of(status).glyph, Icons.logout);
      expect(saidBy(status), isNot(contains("isn't working")));
    });

    testWidgets(
      'refused while this device still believes it is a member: amber, and it '
      'does not claim to know which',
      (tester) async {
          final container = syncingContainer();
        addTearDown(container.dispose);
        // A bare 403 with no closed membership row to explain it. This device
        // genuinely cannot tell "an owner removed me" from "the server is
        // misbehaving", and must not present either as established.
        server.permanentFailure = const SyncTransportException(
          'forbidden',
          statusCode: 403,
        );

        final status = await syncAndRead(tester, container);

        expect(status.health, SyncHealth.accessRefused);
        expect(
          saidBy(status),
          'The server is refusing access to this project. Tap to check.',
        );
        // Amber rather than red: the likeliest cause is administrative and
        // this device cannot tell that from a server fault, so it must not
        // present either as established.
        expect(severityOf(status), SyncSeverity.warning);
      },
    );
  });

  group('a server that will not accept this device', () {
    testWidgets('a 401 signs the device out and says how to come back', (
      tester,
    ) async {
      final container = syncingContainer();
      addTearDown(container.dispose);
      server.permanentFailure = const SyncTransportException(
        'unauthorized',
        statusCode: 401,
      );

      final status = await syncAndRead(tester, container);

      expect(status.health, SyncHealth.sessionEnded);
      expect(saidBy(status), 'Signed out — tap to sign in and resume syncing.');
    });

    testWidgets('a version skew names which side needs updating', (
      tester,
    ) async {
      final container = syncingContainer();
      addTearDown(container.dispose);
      server.permanentFailure = const SyncTransportException(
        syncRefusalSchemaVersion,
        statusCode: 409,
        detail: {'client_schema_major': 1, 'server_schema_major': 2},
      );

      final status = await syncAndRead(tester, container);

      expect(status.health, SyncHealth.versionRefused);
      expect(saidBy(status), contains('too old to sync with the server'));
    });

    testWidgets(
      'a 404 on a sync route is said on the first round, as a server that '
      'does not offer the request — not as offline (task 11.307)',
      (tester) async {
        // Every sync route exists on every server this app can talk to, so
        // a 404 here is a proxy answering for the path, or a server that
        // started without its database and mounted no sync routes. Either
        // way the server address answered, and until task 11.307 the bar
        // said "Offline" for two rounds and "isn't working" on the third —
        // sending a person to check a network that had just delivered a
        // reply. Deterministic like a certificate, so one occurrence is
        // enough; not terminal like one either, so the schedule keeps
        // trying and notices when the server is fixed.
        final container = syncingContainer();
        addTearDown(container.dispose);
        server.permanentFailure = const SyncTransportException(
          SyncTransportException.routeNotOffered,
          statusCode: 404,
        );

        final status = await syncAndRead(tester, container);

        expect(status.health, SyncHealth.versionRefused);
        expect(severityOf(status), SyncSeverity.fault);
        expect(saidBy(status), contains('The server was reached'));
        expect(saidBy(status), contains('cannot tell which'));
        expect(saidBy(status), isNot(contains('Offline')));
        expect(status.lastErrorHeadline, "Server doesn't offer this");
        // The schedule has not stopped: nothing terminal was recorded.
        expect(status.schedule.stoppedReason, isNull);
      },
    );

    testWidgets(
      'a rejected certificate denies the network in its first four words '
      '(task 11.113)',
      (tester) async {
          final container = syncingContainer();
        addTearDown(container.dispose);
        server.permanentFailure = const SyncTransportException(
          SyncTransportException.certificateRejected,
          transportFailure: TransportFailure(
            TransportFaultCause.certificateUntrusted,
            'test-only explanation',
          ),
        );

        final status = await syncAndRead(tester, container);

        expect(status.health, SyncHealth.certificateRejected);
        // One occurrence is enough — the defect this replaced needed three
        // failures to say anything but "Offline".
        expect(saidBy(status), contains('Not a network problem'));
        expect(saidBy(status), isNot(contains('Offline')));
        expect(severityOf(status), SyncSeverity.fault);
      },
    );
  });

  group('a round in flight', () {
    testWidgets('the bar says so, and says nothing about a stale failure', (
      tester,
    ) async {
      final held = _HoldingTransport(server);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) async => db),
          serverTransportProvider.overrideWith((ref) async => held),
          sessionStoreProvider.overrideWithValue(
            FakeSessionStore(
              StoredSession(
                token: 'not-a-real-token',
                userId: userId,
                email: 'sam@example.com',
                expiresAt: DateTime.now().add(const Duration(days: 30)),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final inFlight = await tester.runAsync(() async {
        await activate(container);
        final round = container.read(syncControllerProvider.notifier).syncNow();
        // Long enough for the round to reach the push and stop at the gate.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final snapshot = container.read(syncControllerProvider).requireValue;
        held.release();
        await round;
        return snapshot;
      });

      expect(inFlight!.running, isTrue);
      expect(saidBy(inFlight), 'Syncing…');
      // A round in flight is not a verdict, so it is neither green nor amber.
      expect(severityOf(inFlight), SyncSeverity.quiet);
    });
  });

  // Task 11.58, through the controller rather than the engine alone: the
  // engine test proves the reset; these prove what a person is then shown.
  group('a server whose database was replaced', () {
    testWidgets('once — a restore — is news on the status screen, and the '
        'bar still says synced', (tester) async {
      final container = syncingContainer();
      addTearDown(container.dispose);

      final status = (await tester.runAsync(() async {
        await activate(container);
        final controller = container.read(syncControllerProvider.notifier);
        await controller.syncNow();
        server.replaceDatabase('restored-database');
        await controller.syncNow();
        return container.read(syncControllerProvider).requireValue;
      }))!;

      expect(status.lastReport?.serverDatabaseChanged, isTrue);
      expect(status.serverDatabaseChangedAt, isNotNull);
      expect(status.health, SyncHealth.healthy);
      expect(saidBy(status), contains('Synced'));
      // And the device really did offer its records to the new database —
      // the membership row it published is back on the server.
      expect(
        server.serverRow(Tables.projectMemberships, 'mem-1/$projectId'),
        isNotNull,
      );
    });

    testWidgets('twice in one round is a failure that says why', (
      tester,
    ) async {
      final container = syncingContainer();
      addTearDown(container.dispose);

      final status = (await tester.runAsync(() async {
        await activate(container);
        final controller = container.read(syncControllerProvider.notifier);
        await controller.syncNow();
        var flip = false;
        server.databaseIdPerResponse = () =>
            (flip = !flip) ? 'database-B' : 'database-C';
        await controller.syncNow();
        return container.read(syncControllerProvider).requireValue;
      }))!;

      expect(status.lastFailure, SyncFailureCause.serverDatabaseChanged);
      expect(status.health, SyncHealth.broken);
      expect(status.lastErrorMessage, contains('two different servers'));
      expect(status.remembered?.cause, SyncFailureCause.serverDatabaseChanged);
    });
  });
}



/// A transport that holds its first push open until told otherwise.
///
/// Subclasses nothing and reimplements nothing — it forwards every call to the
/// real fake, so "in flight" is the only thing it models.
class _HoldingTransport implements SyncTransport {
  _HoldingTransport(this._inner);

  final FakeSyncTransport _inner;

  /// **Created on first use, not in the constructor, and that is load-bearing.**
  /// A `Future` remembers the zone it was made in and resumes its listeners
  /// there. Built in the constructor — which runs on `testWidgets`' fake clock
  /// — everything after the gate opens would be queued on a clock nobody is
  /// advancing, and the round would never finish. Built inside the push, it
  /// belongs to the real zone `runAsync` establishes.
  Completer<void>? _gate;

  Completer<void> get _openable => _gate ??= Completer<void>();

  void release() {
    if (!_openable.isCompleted) _openable.complete();
  }

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    await _openable.future;
    return _inner.push(request);
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) => _inner.pull(request);

  @override
  Future<void> ack(SyncAckRequest request) => _inner.ack(request);

  @override
  Future<List<ProjectSummary>> listMyProjects() => _inner.listMyProjects();

  @override
  Future<List<DeletedProjectSummary>> listMyDeletedProjects() =>
      _inner.listMyDeletedProjects();

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
  }) => _inner.rotateJoinCode(projectId: projectId, clearPending: clearPending);

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
  }) =>
      _inner.readmitMember(projectId: projectId, userId: userId, role: role);

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

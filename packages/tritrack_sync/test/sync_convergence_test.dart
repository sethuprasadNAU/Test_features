import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/in_memory_sync_server.dart';

/// Task 10.7's acceptance criteria, checked against the in-memory protocol
/// harness so they run with no infrastructure:
///
/// - a three-peer convergence (two clients + server) reaching identical state
///   regardless of sync order;
/// - an interrupted sync losing nothing;
/// - and above all, **per-`(user, device)` cursors** — the one detail whose
///   absence loses data silently.
/// A minimal client: local rows plus its own pull cursor.
///
/// The cursor lives *here*, not on the server, because the client is the only
/// party that knows what it actually committed.
final class Peer {
  Peer(this.deviceId);

  final String deviceId;
  final Map<String, Map<String, Map<String, Object?>>> tables = {};
  int cursor = 0;

  /// Stores [row] under the key its table's primary key defines.
  ///
  /// Derived rather than passed in, so a peer keys a row it was handed
  /// directly the same way [apply] keys one that arrived over the wire. When
  /// the two disagreed, a row stopped matching itself after a round trip and
  /// the tests silently stopped testing convergence — which is how task
  /// 10.35's key change surfaced here.
  void put(String table, Map<String, Object?> row) {
    tables.putIfAbsent(table, () => {})[keyOf(table, row)] = row;
  }

  SyncRows rowsToPush() => {
    for (final entry in tables.entries) entry.key: entry.value.values.toList(),
  };

  /// Applies a pulled page with the **shared** resolver, exactly as
  /// `ProjectMerger` does locally.
  void apply(SyncRows incoming) {
    incoming.forEach((table, rows) {
      for (final row in rows) {
        final existing = tables[table]?[keyOf(table, row)];
        if (existing == null || MergeResolver.incomingWins(row, existing)) {
          put(table, Map<String, Object?>.of(row));
        }
      }
    });
  }

  Map<String, Object?>? row(String table, String pk) => tables[table]?[pk];

  int get rowCount => tables.values.fold(0, (sum, rows) => sum + rows.length);
}

/// The protocol's row key: every primary-key column, joined — the same
/// definition `SyncService._rowKey` and the app's `syncRowKey` use.
String keyOf(String table, Map<String, Object?> row) =>
    syncTablesByName[table]!.primaryKey.map((c) => row[c]).join('/');

void main() {
  const userId = 'user-1';
  const projectId = 'proj-1';

  /// An `Observations` row key. Since task 10.35 that is
  /// `(observation_id, project_id)`, so the project is part of the name.
  String obsKey(String id, {String project = projectId}) => '$id/$project';

  Map<String, Object?> observation({
    required String id,
    required String userId,
    int revision = 1,
    String updatedAt = '2026-08-01T12:00:00.000Z',
    String device = 'device-A',
    String notes = '',
  }) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'timestamp_local': '2026-08-01T12:00:00.000Z',
    'timestamp_utc': '2026-08-01T12:00:00.000Z',
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'notes': notes,
    'created_at': '2026-08-01T12:00:00.000Z',
    'updated_at': updatedAt,
    'revision': revision,
    'last_modified_by': userId,
    'origin_device_id': device,
  };

  /// One full sync round for a peer: push, then pull to exhaustion, acking each
  /// page — which is what makes a drop mid-stream resumable.
  void syncFully(InMemorySyncServer server, Peer peer) {
    server.push(
      SyncPushRequest(
        projectId: projectId,
        deviceId: peer.deviceId,
        rows: peer.rowsToPush(),
      ),
      userId: userId,
    );
    while (true) {
      final response = server.pull(
        SyncPullRequest(
          projectId: projectId,
          deviceId: peer.deviceId,
          cursor: peer.cursor,
          batchSize: 2,
        ),
        userId: userId,
      );
      if (response.rowCount == 0) break;
      peer.apply(response.rows);
      peer.cursor = response.nextCursor;
      server.ack(
        SyncAckRequest(
          projectId: projectId,
          deviceId: peer.deviceId,
          cursor: peer.cursor,
        ),
        userId: userId,
      );
      if (!response.hasMore) break;
    }
  }

  group('per-(user, device) cursors', () {
    test('rows the laptop already pulled are still delivered to the phone', () {
      // The plan names the exact shape that a naive alternating test misses:
      // sync the laptop TWICE before the phone syncs at all. With a per-user
      // cursor the shared position has advanced past everything, and the
      // phone never receives any of it.
      final server = InMemorySyncServer();
      final laptop = Peer('laptop');
      final phone = Peer('phone');

      laptop.put(
        Tables.observations,
        observation(id: 'obs-1', userId: userId, device: 'laptop'),
      );
      laptop.put(
        Tables.observations,
        observation(id: 'obs-2', userId: userId, device: 'laptop'),
      );

      syncFully(server, laptop);
      syncFully(server, laptop);

      expect(laptop.cursor, greaterThan(0));
      expect(phone.cursor, 0, reason: 'the phone has its own cursor');

      syncFully(server, phone);

      expect(phone.row(Tables.observations, obsKey('obs-1')), isNotNull);
      expect(phone.row(Tables.observations, obsKey('obs-2')), isNotNull);
    });

    test('the two devices hold independent acknowledged positions', () {
      final server = InMemorySyncServer();
      final laptop = Peer('laptop');
      final phone = Peer('phone');

      laptop.put(
        Tables.observations,
        observation(id: 'obs-1', userId: userId, device: 'laptop'),
      );
      syncFully(server, laptop);

      const laptopKey = SyncCursorKey(
        userId: userId,
        deviceId: 'laptop',
        projectId: projectId,
      );
      const phoneKey = SyncCursorKey(
        userId: userId,
        deviceId: 'phone',
        projectId: projectId,
      );

      expect(server.acknowledged[laptopKey], greaterThan(0));
      expect(
        server.acknowledged[phoneKey],
        isNull,
        reason: 'the phone has acknowledged nothing; its position is its own',
      );

      syncFully(server, phone);
      expect(server.acknowledged[phoneKey], greaterThan(0));
    });

    test('an acknowledgement never moves a cursor backwards', () {
      // Retried acks can arrive out of order on a flaky link. Letting the
      // record regress would make 10.11's retention check wrong in the
      // dangerous direction.
      final server = InMemorySyncServer();
      const key = SyncCursorKey(
        userId: userId,
        deviceId: 'laptop',
        projectId: projectId,
      );
      server.ack(
        const SyncAckRequest(
          projectId: projectId,
          deviceId: 'laptop',
          cursor: 10,
        ),
        userId: userId,
      );
      server.ack(
        const SyncAckRequest(
          projectId: projectId,
          deviceId: 'laptop',
          cursor: 3,
        ),
        userId: userId,
      );
      expect(server.acknowledged[key], 10);
    });
  });

  group('three-peer convergence', () {
    test('two clients and a server reach identical state', () {
      final server = InMemorySyncServer();
      final a = Peer('device-A');
      final b = Peer('device-B');

      a.put(
        Tables.observations,
        observation(id: 'obs-a', userId: userId, device: 'device-A'),
      );
      b.put(
        Tables.observations,
        observation(id: 'obs-b', userId: userId, device: 'device-B'),
      );

      // Sync until quiescent.
      for (var round = 0; round < 3; round++) {
        syncFully(server, a);
        syncFully(server, b);
      }

      expect(a.rowCount, b.rowCount);
      expect(a.row(Tables.observations, obsKey('obs-a')), isNotNull);
      expect(a.row(Tables.observations, obsKey('obs-b')), isNotNull);
      expect(b.row(Tables.observations, obsKey('obs-a')), isNotNull);
      expect(b.row(Tables.observations, obsKey('obs-b')), isNotNull);
    });

    test('order does not matter — every interleaving converges alike', () {
      /// Runs the same edits under a given sync order and returns the state
      /// both peers end on.
      List<Map<String, Object?>?> run(List<String> order) {
        final server = InMemorySyncServer();
        final a = Peer('device-A');
        final b = Peer('device-B');

        // Both devices edit the SAME row offline, at different revisions.
        a.put(
          Tables.observations,
          observation(
            id: 'obs-shared',
            userId: userId,
            revision: 2,
            updatedAt: '2026-08-01T12:00:00.000Z',
            device: 'device-A',
            notes: 'from A',
          ),
        );
        b.put(
          Tables.observations,
          observation(
            id: 'obs-shared',
            userId: userId,
            revision: 5,
            updatedAt: '2026-08-02T12:00:00.000Z',
            device: 'device-B',
            notes: 'from B',
          ),
        );

        for (final step in order) {
          syncFully(server, step == 'a' ? a : b);
        }
        // Settle.
        for (var i = 0; i < 3; i++) {
          syncFully(server, a);
          syncFully(server, b);
        }
        return [
          a.row(Tables.observations, obsKey('obs-shared')),
          b.row(Tables.observations, obsKey('obs-shared')),
        ];
      }

      final abFirst = run(['a', 'b']);
      final baFirst = run(['b', 'a']);
      final interleaved = run(['a', 'b', 'a', 'b']);

      // Both peers agree with each other...
      for (final result in [abFirst, baFirst, interleaved]) {
        expect(result[0]!['notes'], result[1]!['notes']);
        expect(result[0]!['revision'], result[1]!['revision']);
      }
      // ...and every order reaches the same winner (B's higher revision).
      expect(abFirst[0]!['notes'], 'from B');
      expect(baFirst[0]!['notes'], 'from B');
      expect(interleaved[0]!['notes'], 'from B');
    });

    test('a repeat sync of a converged pair changes nothing', () {
      // No churn: once settled, another round must not rewrite anything. This
      // is what the identity design is protecting.
      final server = InMemorySyncServer();
      final a = Peer('device-A');
      final b = Peer('device-B');
      a.put(
        Tables.observations,
        observation(id: 'obs-a', userId: userId, device: 'device-A'),
      );
      for (var i = 0; i < 3; i++) {
        syncFully(server, a);
        syncFully(server, b);
      }
      final cursorA = a.cursor;
      final cursorB = b.cursor;
      final serverRows = server.rowCount;

      syncFully(server, a);
      syncFully(server, b);

      expect(a.cursor, cursorA);
      expect(b.cursor, cursorB);
      expect(server.rowCount, serverRows);
    });
  });

  group('chunking and interruption', () {
    test('a large first sync arrives completely across many pages', () {
      final server = InMemorySyncServer();
      final source = Peer('device-A');
      final joiner = Peer('device-B');

      for (var i = 0; i < 25; i++) {
        source.put(
          Tables.observations,
          observation(id: 'obs-$i', userId: userId, device: 'device-A'),
        );
      }
      syncFully(server, source);
      syncFully(server, joiner);

      expect(joiner.rowCount, 25);
      // Paged, not delivered in one unbounded response.
      expect(
        server.pullLog.where((p) => p.key.deviceId == 'device-B').length,
        greaterThan(5),
      );
    });

    test('an interruption mid-stream loses nothing and resumes', () {
      final server = InMemorySyncServer();
      final source = Peer('device-A');
      final joiner = Peer('device-B');

      for (var i = 0; i < 10; i++) {
        source.put(
          Tables.observations,
          observation(id: 'obs-$i', userId: userId, device: 'device-A'),
        );
      }
      syncFully(server, source);

      // Two pages, then "the connection drops": stop pulling.
      for (var page = 0; page < 2; page++) {
        final response = server.pull(
          SyncPullRequest(
            projectId: projectId,
            deviceId: joiner.deviceId,
            cursor: joiner.cursor,
            batchSize: 3,
          ),
          userId: userId,
        );
        joiner.apply(response.rows);
        joiner.cursor = response.nextCursor;
      }
      final partial = joiner.rowCount;
      expect(partial, greaterThan(0));
      expect(partial, lessThan(10));

      // Resume from the client's own cursor — not from zero.
      syncFully(server, joiner);
      expect(joiner.rowCount, 10);
    });

    test('a page received but never committed is re-offered, not skipped', () {
      // The reason ack is a separate message: the server must not treat
      // "sent" as "stored". A sync that dies between receiving a page and
      // committing it re-receives it, which is harmless because the merge is
      // idempotent — whereas the alternative loses it silently.
      final server = InMemorySyncServer();
      final source = Peer('device-A');
      final joiner = Peer('device-B');

      for (var i = 0; i < 4; i++) {
        source.put(
          Tables.observations,
          observation(id: 'obs-$i', userId: userId, device: 'device-A'),
        );
      }
      syncFully(server, source);

      // Receive a page and deliberately DON'T advance the cursor or ack,
      // modelling a crash before the local commit.
      final first = server.pull(
        SyncPullRequest(
          projectId: projectId,
          deviceId: joiner.deviceId,
          cursor: 0,
          batchSize: 2,
        ),
        userId: userId,
      );
      expect(first.rowCount, 2);

      // Same cursor again: the same rows come back.
      final retry = server.pull(
        SyncPullRequest(
          projectId: projectId,
          deviceId: joiner.deviceId,
          cursor: 0,
          batchSize: 2,
        ),
        userId: userId,
      );
      expect(retry.rowCount, 2);
      expect(
        retry.rows[Tables.observations]!.map((r) => r['observation_id']),
        first.rows[Tables.observations]!.map((r) => r['observation_id']),
      );

      syncFully(server, joiner);
      expect(joiner.rowCount, 4);
    });

    test('remaining counts down so progress is reportable', () {
      final server = InMemorySyncServer();
      final source = Peer('device-A');
      for (var i = 0; i < 7; i++) {
        source.put(
          Tables.observations,
          observation(id: 'obs-$i', userId: userId, device: 'device-A'),
        );
      }
      syncFully(server, source);

      var cursor = 0;
      final remainingSeen = <int>[];
      while (true) {
        final response = server.pull(
          SyncPullRequest(
            projectId: projectId,
            deviceId: 'device-B',
            cursor: cursor,
            batchSize: 3,
          ),
          userId: userId,
        );
        if (response.rowCount == 0) break;
        remainingSeen.add(response.remaining);
        cursor = response.nextCursor;
      }
      // Strictly decreasing, ending at zero — an indeterminate spinner is what
      // this replaces.
      expect(remainingSeen.first, greaterThan(0));
      expect(remainingSeen.last, 0);
      for (var i = 1; i < remainingSeen.length; i++) {
        expect(remainingSeen[i], lessThan(remainingSeen[i - 1]));
      }
    });
  });

  group('project scoping', () {
    test('a row claiming another project is rejected, not rewritten', () {
      final server = InMemorySyncServer();
      final response = server.push(
        SyncPushRequest(
          projectId: projectId,
          deviceId: 'device-A',
          rows: {
            Tables.observations: [
              {
                ...observation(id: 'obs-x', userId: userId),
                'project_id': 'someone-elses-project',
              },
            ],
          },
        ),
        userId: userId,
      );
      expect(
        // Keyed by the project the row *claims*, not the one the request is
        // scoped to — the outcome has to be reported under the key the caller
        // sent, or the caller cannot match it to the row it pushed.
        response
            .outcomes['${Tables.observations}/${obsKey('obs-x', project: 'someone-elses-project')}'],
        SyncRowOutcome.unauthorized,
      );
      expect(server.rowCount, 0);
    });
  });

  group('losing rows are reported', () {
    test('a row that loses last-write-wins is named, not silently dropped', () {
      final server = InMemorySyncServer();
      server.push(
        SyncPushRequest(
          projectId: projectId,
          deviceId: 'device-A',
          rows: {
            Tables.observations: [
              observation(id: 'obs-1', userId: userId, revision: 5),
            ],
          },
        ),
        userId: userId,
      );
      final response = server.push(
        SyncPushRequest(
          projectId: projectId,
          deviceId: 'device-B',
          rows: {
            Tables.observations: [
              observation(id: 'obs-1', userId: userId, revision: 2),
            ],
          },
        ),
        userId: userId,
      );
      expect(
        response.outcomes['${Tables.observations}/${obsKey('obs-1')}'],
        SyncRowOutcome.lostToServer,
      );
      expect(response.applied, 0);
    });
  });
}

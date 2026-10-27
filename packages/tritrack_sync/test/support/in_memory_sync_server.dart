import 'package:tritrack_sync/tritrack_sync.dart';

/// An in-memory server implementing the task 10.7 protocol.
///
/// **Why this exists rather than only a Postgres integration test.** The
/// properties that matter most here — per-`(user, device)` cursor independence,
/// resumability, and three-peer convergence — are properties of the *protocol*,
/// not of Postgres. Expressing them against a fake that follows the same rules
/// means they are checked on every `dart test` run with no infrastructure
/// (Phase 10's invariant 5), and it means a regression in the protocol's logic
/// is caught even when nobody has a database up. The Postgres tests prove the
/// real storage layer honours the same contract; they do not replace this.
///
/// Faithful to the real server in the ways that matter:
/// - `server_seq` is allocated from one monotonic counter, commit-ordered by
///   construction (single-threaded here).
/// - Merge decisions go through the **shared** `MergeResolver`, not a
///   reimplementation — the same reason the real server does.
/// - A `skip` does not bump `server_seq`.
/// - Cursors are stored per `(user, device, project)` but are **not** used to
///   decide delivery; the client's requested cursor is.
class InMemorySyncServer {
  InMemorySyncServer();

  /// `table -> primaryKey -> row`, with `_serverSeq` held alongside.
  final Map<String, Map<String, Map<String, Object?>>> _tables = {};
  final Map<String, Map<String, int>> _seqByRow = {};

  int _nextSeq = 0;

  /// Recorded acknowledgements, for assertions about bookkeeping.
  final Map<SyncCursorKey, int> acknowledged = {};

  /// Every pull the server answered, for assertions about paging.
  final List<({SyncCursorKey key, int cursor, int returned})> pullLog = [];

  int get rowCount => _tables.values.fold(0, (sum, rows) => sum + rows.length);

  SyncPushResponse push(SyncPushRequest request, {required String userId}) {
    final outcomes = <String, SyncRowOutcome>{};
    var applied = 0;
    int? highest;

    for (final table in syncTables) {
      for (final row in request.rows[table.name] ?? const []) {
        final key = _keyOf(table, row);
        if (key == null) continue;
        final reference = '${table.name}/$key';

        if (RowValidator.validate(table.name, row).isNotEmpty) {
          outcomes[reference] = SyncRowOutcome.invalid;
          continue;
        }
        final scope = table.projectScopeColumn;
        if (scope != null && row[scope] != request.projectId) {
          outcomes[reference] = SyncRowOutcome.unauthorized;
          continue;
        }

        final store = _tables.putIfAbsent(table.name, () => {});
        final existing = store[key];
        final decision = decideMerge(incoming: row, existing: existing);

        switch (decision) {
          case MergeAction.skip:
            // No stored change, so no new sequence — bumping here would
            // redeliver an unchanged row to every other device forever.
            outcomes[reference] = SyncRowOutcome.lostToServer;
          case MergeAction.insert:
          case MergeAction.update:
            final seq = ++_nextSeq;
            store[key] = Map<String, Object?>.of(row);
            _seqByRow.putIfAbsent(table.name, () => {})[key] = seq;
            highest = seq;
            outcomes[reference] = decision == MergeAction.insert
                ? SyncRowOutcome.inserted
                : SyncRowOutcome.updated;
            applied++;
        }
      }
    }

    return SyncPushResponse(
      applied: applied,
      outcomes: outcomes,
      highestServerSeq: highest,
    );
  }

  SyncPullResponse pull(SyncPullRequest request, {required String userId}) {
    final key = SyncCursorKey(
      userId: userId,
      deviceId: request.deviceId,
      projectId: request.projectId,
    );

    final candidates = <({String table, String pk, int seq})>[];
    for (final table in syncTables) {
      final rows = _tables[table.name] ?? const {};
      final seqs = _seqByRow[table.name] ?? const {};
      for (final entry in rows.entries) {
        final seq = seqs[entry.key];
        if (seq == null || seq <= request.cursor) continue;
        final scope = table.projectScopeColumn;
        if (scope != null && entry.value[scope] != request.projectId) continue;
        candidates.add((table: table.name, pk: entry.key, seq: seq));
      }
    }
    candidates.sort((a, b) => a.seq.compareTo(b.seq));
    final page = candidates.take(request.batchSize).toList();

    final rows = <String, List<Map<String, Object?>>>{};
    for (final item in page) {
      rows
          .putIfAbsent(item.table, () => [])
          .add(Map<String, Object?>.of(_tables[item.table]![item.pk]!));
    }

    pullLog.add((key: key, cursor: request.cursor, returned: page.length));

    return SyncPullResponse(
      rows: rows,
      nextCursor: page.isEmpty ? request.cursor : page.last.seq,
      remaining: candidates.length - page.length,
    );
  }

  /// Records that a device committed up to a cursor. Monotonic, like the real
  /// store — a retried older ack must not move the record backwards.
  void ack(SyncAckRequest request, {required String userId}) {
    final key = SyncCursorKey(
      userId: userId,
      deviceId: request.deviceId,
      projectId: request.projectId,
    );
    final current = acknowledged[key] ?? 0;
    acknowledged[key] = request.cursor > current ? request.cursor : current;
  }

  Map<String, Object?>? row(String table, String primaryKey) =>
      _tables[table]?[primaryKey];

  String? _keyOf(SyncTable table, Map<String, Object?> row) {
    final parts = <String>[];
    for (final column in table.primaryKey) {
      final value = row[column];
      if (value is! String || value.isEmpty) return null;
      parts.add(value);
    }
    return parts.join('/');
  }
}

enum MergeAction { insert, update, skip }

/// Uses the shared resolver, deliberately — a second implementation of the
/// merge rule in the test harness would let a real disagreement pass unnoticed.
MergeAction decideMerge({
  required Map<String, Object?> incoming,
  required Map<String, Object?>? existing,
}) {
  if (existing == null) return MergeAction.insert;
  return MergeResolver.incomingWins(incoming, existing)
      ? MergeAction.update
      : MergeAction.skip;
}

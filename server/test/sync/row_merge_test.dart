import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 10.5's acceptance criterion: "LWW outcomes are identical to the
/// client's `MergeResolver` for the same inputs."
///
/// Parity here is structural, not coincidental — `RowMerge` *calls* the shared
/// `MergeResolver` rather than reimplementing the comparison (in Dart or, worse,
/// in SQL). These tests exist to keep it that way: the exhaustive group at the
/// bottom would start failing the moment someone replaced the delegation with
/// a second implementation that disagrees on any input.
void main() {
  final receivedAt = DateTime.utc(2026, 8, 1, 12, 0, 0);

  Map<String, Object?> row({
    int revision = 1,
    String updatedAt = '2026-07-30T12:00:00.000Z',
    String? device,
    String? createdAt = '2026-07-29T12:00:00.000Z',
    String? deletedAt,
  }) => {
    'revision': revision,
    'updated_at': updatedAt,
    'created_at': createdAt,
    'origin_device_id': device,
    'deleted_at': deletedAt,
  };

  group('action selection', () {
    test('a row the server has never seen is inserted', () {
      final decision = RowMerge.decide(
        incoming: row(),
        existing: null,
        receivedAt: receivedAt,
      );
      expect(decision.action, MergeAction.insert);
      expect(decision.losingRow, isNull);
      expect(decision.changesStoredRow, isTrue);
    });

    test('a higher-revision incoming row updates and reports the loser', () {
      final existing = row(revision: 1);
      final decision = RowMerge.decide(
        incoming: row(revision: 2),
        existing: existing,
        receivedAt: receivedAt,
      );
      expect(decision.action, MergeAction.update);
      expect(decision.losingRow, same(existing));
      expect(decision.changesStoredRow, isTrue);
    });

    test('a lower-revision incoming row is skipped', () {
      final decision = RowMerge.decide(
        incoming: row(revision: 1),
        existing: row(revision: 2),
        receivedAt: receivedAt,
      );
      expect(decision.action, MergeAction.skip);
      expect(decision.losingRow, isNull);
      // Nothing about the stored row changed, so its server_seq must not be
      // bumped — bumping it would redeliver an unchanged row to every other
      // device on their next pull, forever.
      expect(decision.changesStoredRow, isFalse);
    });

    test('an identical row is skipped, not rewritten', () {
      final decision = RowMerge.decide(
        incoming: row(revision: 3, device: 'device-A'),
        existing: row(revision: 3, device: 'device-A'),
        receivedAt: receivedAt,
      );
      expect(decision.action, MergeAction.skip);
    });

    test('a tombstone rides along with whichever row wins', () {
      final decision = RowMerge.decide(
        incoming: row(revision: 5, deletedAt: '2026-07-31T00:00:00.000Z'),
        existing: row(revision: 4),
        receivedAt: receivedAt,
      );
      expect(decision.action, MergeAction.update);
    });

    test('a stale tombstone does not bury a newer live row', () {
      final decision = RowMerge.decide(
        incoming: row(revision: 2, deletedAt: '2026-07-31T00:00:00.000Z'),
        existing: row(revision: 6),
        receivedAt: receivedAt,
      );
      expect(decision.action, MergeAction.skip);
    });
  });

  group('skew is recorded independently of who wins', () {
    test('a losing row still reports its skew', () {
      // A device with a broken clock is worth knowing about even when its
      // rows lose — that is often *why* they lose.
      final decision = RowMerge.decide(
        incoming: row(revision: 1, updatedAt: '2030-01-01T00:00:00.000Z'),
        existing: row(revision: 99),
        receivedAt: receivedAt,
      );
      expect(decision.action, MergeAction.skip);
      expect(decision.skewFlag, ClockSkewFlag.future);
    });

    test('a winning row reports its skew', () {
      final decision = RowMerge.decide(
        incoming: row(revision: 99, updatedAt: '2030-01-01T00:00:00.000Z'),
        existing: row(revision: 1),
        receivedAt: receivedAt,
      );
      expect(decision.action, MergeAction.update);
      expect(decision.skewFlag, ClockSkewFlag.future);
    });

    test('an inserted row reports its skew', () {
      final decision = RowMerge.decide(
        incoming: row(updatedAt: '1970-01-01T00:00:00.000Z'),
        existing: null,
        receivedAt: receivedAt,
      );
      expect(decision.action, MergeAction.insert);
      expect(decision.skewFlag, ClockSkewFlag.implausiblePast);
    });

    test('a clean row reports no skew', () {
      final decision = RowMerge.decide(
        incoming: row(),
        existing: null,
        receivedAt: receivedAt,
      );
      expect(decision.skewFlag, isNull);
    });
  });

  group('the server never rewrites what the device sent', () {
    test('a skewed incoming row keeps its own updated_at verbatim', () {
      // Rewriting it would destroy the field record's own timestamp AND make
      // two devices converge differently depending on whether their data
      // passed through the server. Detect, record, never correct.
      const skewed = '2030-01-01T00:00:00.000Z';
      final incoming = row(updatedAt: skewed);
      final decision = RowMerge.decide(
        incoming: incoming,
        existing: null,
        receivedAt: receivedAt,
      );
      expect(decision.skewFlag, ClockSkewFlag.future);
      expect(incoming['updated_at'], skewed);
    });

    test('deciding does not mutate either input map', () {
      final incoming = row(revision: 2);
      final existing = row(revision: 1);
      final incomingBefore = Map.of(incoming);
      final existingBefore = Map.of(existing);
      RowMerge.decide(
        incoming: incoming,
        existing: existing,
        receivedAt: receivedAt,
      );
      expect(incoming, incomingBefore);
      expect(existing, existingBefore);
    });
  });

  group('parity with the client MergeResolver', () {
    // Exhaustive over the whole tie-break ladder: revision, then updated_at,
    // then origin_device_id, then fully-equal. For every pair, the server's
    // chosen action must agree with what the client's resolver would decide.
    const revisions = [0, 1, 2];
    const timestamps = [
      '2026-07-29T12:00:00.000Z',
      '2026-07-30T12:00:00.000Z',
      '2026-07-30T12:00:00.500Z',
    ];
    const devices = [null, 'device-A', 'device-B'];

    test('agrees with MergeResolver.incomingWins on every combination', () {
      var compared = 0;
      for (final incomingRevision in revisions) {
        for (final existingRevision in revisions) {
          for (final incomingTimestamp in timestamps) {
            for (final existingTimestamp in timestamps) {
              for (final incomingDevice in devices) {
                for (final existingDevice in devices) {
                  final incoming = row(
                    revision: incomingRevision,
                    updatedAt: incomingTimestamp,
                    device: incomingDevice,
                  );
                  final existing = row(
                    revision: existingRevision,
                    updatedAt: existingTimestamp,
                    device: existingDevice,
                  );
                  final decision = RowMerge.decide(
                    incoming: incoming,
                    existing: existing,
                    receivedAt: receivedAt,
                  );
                  final clientSaysIncomingWins = MergeResolver.incomingWins(
                    incoming,
                    existing,
                  );
                  expect(
                    decision.action == MergeAction.update,
                    clientSaysIncomingWins,
                    reason:
                        'rev $incomingRevision/$existingRevision, '
                        'ts $incomingTimestamp/$existingTimestamp, '
                        'dev $incomingDevice/$existingDevice',
                  );
                  compared++;
                }
              }
            }
          }
        }
      }
      // Guards against the loops silently collapsing to nothing.
      expect(
        compared,
        revisions.length *
            revisions.length *
            timestamps.length *
            timestamps.length *
            devices.length *
            devices.length,
      );
    });

    test('a row missing every sync column is handled without throwing', () {
      // MergeResolver treats absent fields as oldest; the server must not
      // diverge by, say, throwing on a null revision.
      final decision = RowMerge.decide(
        incoming: <String, Object?>{},
        existing: row(revision: 1),
        receivedAt: receivedAt,
      );
      expect(decision.action, MergeAction.skip);
      expect(
        MergeResolver.incomingWins(<String, Object?>{}, row(revision: 1)),
        isFalse,
      );
    });
  });
}

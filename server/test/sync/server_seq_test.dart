import 'dart:async';

import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// A [SeqCounterStore] that models the *real* Postgres behaviour this design
/// depends on: `UPDATE ... RETURNING` on one row takes a write lock held until
/// the caller's transaction commits, so a second transaction cannot obtain a
/// higher value until the first has committed.
///
/// Modelling that here lets the commit-ordering property be tested without a
/// live database. It is not a substitute for the Postgres integration test
/// (`test/integration/postgres_sync_test.dart`) — that one proves the real
/// driver and the real lock behave as modelled — but it does pin the *contract*
/// so a future change to `ServerSeq` that breaks the ordering fails here, in a
/// test that always runs.
class FakeLockingCounter implements SeqCounterStore {
  FakeLockingCounter();

  int _nextValue = 0;
  Completer<void>? _heldBy;

  /// Values handed out, in the order they were granted.
  final List<int> granted = [];

  /// Transactions that committed, in commit order.
  final List<int> commitOrder = [];

  @override
  Future<int> bumpAndReturn(int by) async {
    // Wait for any in-flight holder to commit — the row lock.
    while (_heldBy != null) {
      await _heldBy!.future;
    }
    _heldBy = Completer<void>();
    _nextValue += by;
    granted.add(_nextValue);
    return _nextValue;
  }

  /// Releases the lock, as committing the transaction would.
  void commit(int highestValue) {
    commitOrder.add(highestValue);
    final held = _heldBy;
    _heldBy = null;
    held?.complete();
  }
}

void main() {
  group('block arithmetic', () {
    test('a single-value block is that value', () async {
      final counter = FakeLockingCounter();
      final block = await ServerSeq.reserve(counter, 1);
      expect(block.first, 1);
      expect(block.last, 1);
      expect(block.count, 1);
      expect(block.values, [1]);
    });

    test('a multi-value block is contiguous and ascending', () async {
      final counter = FakeLockingCounter();
      final block = await ServerSeq.reserve(counter, 5);
      expect(block.first, 1);
      expect(block.last, 5);
      expect(block.values, [1, 2, 3, 4, 5]);
    });

    test('consecutive blocks do not overlap', () async {
      final counter = FakeLockingCounter();
      final first = await ServerSeq.reserve(counter, 3);
      counter.commit(first.last);
      final second = await ServerSeq.reserve(counter, 2);
      counter.commit(second.last);

      expect(first.values, [1, 2, 3]);
      expect(second.values, [4, 5]);
      expect(first.values.toSet().intersection(second.values.toSet()), isEmpty);
    });

    test(
      'a non-positive count is rejected rather than silently reserving nothing',
      () {
        final counter = FakeLockingCounter();
        expect(() => ServerSeq.reserve(counter, 0), throwsArgumentError);
        expect(() => ServerSeq.reserve(counter, -1), throwsArgumentError);
      },
    );
  });

  group('commit ordering — the property the cursor depends on', () {
    test(
      'a transaction cannot get a higher value until the holder commits',
      () async {
        // This is the whole reason for the counter row rather than a Postgres
        // SEQUENCE. If B could take 101 while A still held 100 uncommitted, a
        // reader could advance its cursor to 101 and never receive row 100.
        final counter = FakeLockingCounter();

        final blockA = await ServerSeq.reserve(counter, 1);
        expect(blockA.first, 1);

        var bGranted = false;
        final bFuture = ServerSeq.reserve(counter, 1).then((block) {
          bGranted = true;
          return block;
        });

        // B must still be blocked while A holds the lock.
        await Future<void>.delayed(Duration.zero);
        expect(
          bGranted,
          isFalse,
          reason: 'B obtained a sequence value before A committed',
        );

        counter.commit(blockA.last);
        final blockB = await bFuture;

        expect(blockB.first, 2);
        // A committed strictly before B was granted 2, so any reader that can
        // see 2 can also see 1.
        expect(counter.commitOrder, [1]);
      },
    );

    test(
      'granted order equals commit order across many transactions',
      () async {
        final counter = FakeLockingCounter();
        final granted = <int>[];

        for (var i = 0; i < 25; i++) {
          final block = await ServerSeq.reserve(counter, 1);
          granted.add(block.first);
          counter.commit(block.last);
        }

        expect(granted, counter.commitOrder);
        // Strictly increasing, no gaps, no repeats.
        expect(granted, List.generate(25, (i) => i + 1));
      },
    );

    test(
      'interleaved concurrent reservations still come out monotonic',
      () async {
        final counter = FakeLockingCounter();
        final results = <int>[];

        Future<void> transaction(int size) async {
          final block = await ServerSeq.reserve(counter, size);
          results.addAll(block.values);
          counter.commit(block.last);
        }

        // Fire several without awaiting, so they contend for the lock.
        await Future.wait([
          transaction(2),
          transaction(3),
          transaction(1),
          transaction(4),
        ]);

        expect(
          results,
          List.generate(10, (i) => i + 1),
          reason: 'values must be a contiguous ascending run with no gaps',
        );
        expect(counter.commitOrder.length, 4);
      },
    );
  });
}

/// Allocation of `server_seq`, the delta cursor's clock (task 10.5).
///
/// See `postgres_schema.dart`'s `createSyncSeqCounter` for the full reasoning
/// on why this is a locked counter row rather than a Postgres `SEQUENCE`. The
/// short version: a bare sequence hands out values in request order while
/// transactions commit in a different order, so a reader can advance its cursor
/// past a value that has not committed yet and never receive that row. This
/// allocator exists to make assignment order equal commit order.
library;

/// A contiguous, ascending block of `server_seq` values reserved for one
/// transaction.
class SeqBlock {
  const SeqBlock({required this.first, required this.count})
    : assert(count > 0, 'a block must reserve at least one value');

  /// Lowest value in the block.
  final int first;

  /// How many values were reserved.
  final int count;

  /// Highest value in the block.
  int get last => first + count - 1;

  /// The reserved values, ascending.
  Iterable<int> get values => Iterable.generate(count, (i) => first + i);
}

/// Minimal contract this allocator needs from a database handle, so the
/// allocation logic can be exercised without a live Postgres (see
/// `test/sync/server_seq_test.dart`). The real implementation is a thin
/// wrapper over a `postgres` connection inside an open transaction.
abstract interface class SeqCounterStore {
  /// Atomically adds [by] to the counter and returns its **new** value.
  ///
  /// Must be `UPDATE sync_seq_counter SET next_value = next_value + $by
  /// RETURNING next_value` executed inside the caller's transaction — the
  /// row-level write lock it takes is the entire correctness mechanism and is
  /// only held until *that* transaction commits. Implementing this as a
  /// separate short transaction, or with `SELECT` then `UPDATE`, breaks the
  /// commit-ordering guarantee and silently reintroduces the lost-row bug.
  Future<int> bumpAndReturn(int by);
}

abstract final class ServerSeq {
  /// Reserves [count] consecutive values for the current transaction.
  ///
  /// One counter bump per transaction rather than one per row: the lock is
  /// taken once, and values within a block need no ordering guarantee relative
  /// to each other because they all become visible together at commit.
  static Future<SeqBlock> reserve(SeqCounterStore store, int count) async {
    if (count <= 0) {
      throw ArgumentError.value(count, 'count', 'must be positive');
    }
    final newValue = await store.bumpAndReturn(count);
    // The counter now sits at the highest reserved value, so the block runs
    // from (newValue - count + 1) up to newValue.
    return SeqBlock(first: newValue - count + 1, count: count);
  }
}

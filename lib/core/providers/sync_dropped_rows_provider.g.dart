// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sync_dropped_rows_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Rows this device refused to store when the server sent them (task 11.44)
/// — the inbound mirror of [syncHeldRowsProvider], and the reviewable half of
/// "something did not arrive, and here is why."
///
/// Same shape and lifetime as `syncHeldRowsProvider`: not `keepAlive`, read by
/// the status screen, and invalidated by `SyncController` after every sync
/// round so it cannot go stale while something is watching it.

@ProviderFor(syncDroppedRows)
final syncDroppedRowsProvider = SyncDroppedRowsFamily._();

/// Rows this device refused to store when the server sent them (task 11.44)
/// — the inbound mirror of [syncHeldRowsProvider], and the reviewable half of
/// "something did not arrive, and here is why."
///
/// Same shape and lifetime as `syncHeldRowsProvider`: not `keepAlive`, read by
/// the status screen, and invalidated by `SyncController` after every sync
/// round so it cannot go stale while something is watching it.

final class SyncDroppedRowsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<DroppedRow>>,
          List<DroppedRow>,
          FutureOr<List<DroppedRow>>
        >
    with $FutureModifier<List<DroppedRow>>, $FutureProvider<List<DroppedRow>> {
  /// Rows this device refused to store when the server sent them (task 11.44)
  /// — the inbound mirror of [syncHeldRowsProvider], and the reviewable half of
  /// "something did not arrive, and here is why."
  ///
  /// Same shape and lifetime as `syncHeldRowsProvider`: not `keepAlive`, read by
  /// the status screen, and invalidated by `SyncController` after every sync
  /// round so it cannot go stale while something is watching it.
  SyncDroppedRowsProvider._({
    required SyncDroppedRowsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'syncDroppedRowsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$syncDroppedRowsHash();

  @override
  String toString() {
    return r'syncDroppedRowsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<DroppedRow>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<DroppedRow>> create(Ref ref) {
    final argument = this.argument as String;
    return syncDroppedRows(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is SyncDroppedRowsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$syncDroppedRowsHash() => r'f9325895341389b4dea789012604395b78bf1ae1';

/// Rows this device refused to store when the server sent them (task 11.44)
/// — the inbound mirror of [syncHeldRowsProvider], and the reviewable half of
/// "something did not arrive, and here is why."
///
/// Same shape and lifetime as `syncHeldRowsProvider`: not `keepAlive`, read by
/// the status screen, and invalidated by `SyncController` after every sync
/// round so it cannot go stale while something is watching it.

final class SyncDroppedRowsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<List<DroppedRow>>, String> {
  SyncDroppedRowsFamily._()
    : super(
        retry: null,
        name: r'syncDroppedRowsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// Rows this device refused to store when the server sent them (task 11.44)
  /// — the inbound mirror of [syncHeldRowsProvider], and the reviewable half of
  /// "something did not arrive, and here is why."
  ///
  /// Same shape and lifetime as `syncHeldRowsProvider`: not `keepAlive`, read by
  /// the status screen, and invalidated by `SyncController` after every sync
  /// round so it cannot go stale while something is watching it.

  SyncDroppedRowsProvider call(String projectId) =>
      SyncDroppedRowsProvider._(argument: projectId, from: this);

  @override
  String toString() => r'syncDroppedRowsProvider';
}

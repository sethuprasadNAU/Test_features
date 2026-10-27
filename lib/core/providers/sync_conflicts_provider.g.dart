// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sync_conflicts_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Superseded local edits for [projectId] the user has not yet acknowledged —
/// task 10.12's "reviewable list of an edit you made was superseded."
///
/// Not `keepAlive`: unlike [syncControllerProvider], nothing needs this held
/// warm in the background — it is read by the status screen and invalidated
/// by [SyncController] after a sync round, which is enough to stay current
/// while anything is actually watching it.

@ProviderFor(syncConflicts)
final syncConflictsProvider = SyncConflictsFamily._();

/// Superseded local edits for [projectId] the user has not yet acknowledged —
/// task 10.12's "reviewable list of an edit you made was superseded."
///
/// Not `keepAlive`: unlike [syncControllerProvider], nothing needs this held
/// warm in the background — it is read by the status screen and invalidated
/// by [SyncController] after a sync round, which is enough to stay current
/// while anything is actually watching it.

final class SyncConflictsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<SyncConflict>>,
          List<SyncConflict>,
          FutureOr<List<SyncConflict>>
        >
    with
        $FutureModifier<List<SyncConflict>>,
        $FutureProvider<List<SyncConflict>> {
  /// Superseded local edits for [projectId] the user has not yet acknowledged —
  /// task 10.12's "reviewable list of an edit you made was superseded."
  ///
  /// Not `keepAlive`: unlike [syncControllerProvider], nothing needs this held
  /// warm in the background — it is read by the status screen and invalidated
  /// by [SyncController] after a sync round, which is enough to stay current
  /// while anything is actually watching it.
  SyncConflictsProvider._({
    required SyncConflictsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'syncConflictsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$syncConflictsHash();

  @override
  String toString() {
    return r'syncConflictsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<SyncConflict>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<SyncConflict>> create(Ref ref) {
    final argument = this.argument as String;
    return syncConflicts(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is SyncConflictsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$syncConflictsHash() => r'f887496ccf48dc7f6fd3b936976143e416348f9e';

/// Superseded local edits for [projectId] the user has not yet acknowledged —
/// task 10.12's "reviewable list of an edit you made was superseded."
///
/// Not `keepAlive`: unlike [syncControllerProvider], nothing needs this held
/// warm in the background — it is read by the status screen and invalidated
/// by [SyncController] after a sync round, which is enough to stay current
/// while anything is actually watching it.

final class SyncConflictsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<List<SyncConflict>>, String> {
  SyncConflictsFamily._()
    : super(
        retry: null,
        name: r'syncConflictsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// Superseded local edits for [projectId] the user has not yet acknowledged —
  /// task 10.12's "reviewable list of an edit you made was superseded."
  ///
  /// Not `keepAlive`: unlike [syncControllerProvider], nothing needs this held
  /// warm in the background — it is read by the status screen and invalidated
  /// by [SyncController] after a sync round, which is enough to stay current
  /// while anything is actually watching it.

  SyncConflictsProvider call(String projectId) =>
      SyncConflictsProvider._(argument: projectId, from: this);

  @override
  String toString() => r'syncConflictsProvider';
}

/// [syncConflictsProvider] grouped into one entry per import or sync round —
/// task 10.87. The screen renders these, not the flat list.

@ProviderFor(syncConflictEvents)
final syncConflictEventsProvider = SyncConflictEventsFamily._();

/// [syncConflictsProvider] grouped into one entry per import or sync round —
/// task 10.87. The screen renders these, not the flat list.

final class SyncConflictEventsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<SyncConflictEvent>>,
          List<SyncConflictEvent>,
          FutureOr<List<SyncConflictEvent>>
        >
    with
        $FutureModifier<List<SyncConflictEvent>>,
        $FutureProvider<List<SyncConflictEvent>> {
  /// [syncConflictsProvider] grouped into one entry per import or sync round —
  /// task 10.87. The screen renders these, not the flat list.
  SyncConflictEventsProvider._({
    required SyncConflictEventsFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'syncConflictEventsProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$syncConflictEventsHash();

  @override
  String toString() {
    return r'syncConflictEventsProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<SyncConflictEvent>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<SyncConflictEvent>> create(Ref ref) {
    final argument = this.argument as String;
    return syncConflictEvents(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is SyncConflictEventsProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$syncConflictEventsHash() =>
    r'53e03b64934ccd3eb7984b7ced94a7b090db7b30';

/// [syncConflictsProvider] grouped into one entry per import or sync round —
/// task 10.87. The screen renders these, not the flat list.

final class SyncConflictEventsFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<List<SyncConflictEvent>>, String> {
  SyncConflictEventsFamily._()
    : super(
        retry: null,
        name: r'syncConflictEventsProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// [syncConflictsProvider] grouped into one entry per import or sync round —
  /// task 10.87. The screen renders these, not the flat list.

  SyncConflictEventsProvider call(String projectId) =>
      SyncConflictEventsProvider._(argument: projectId, from: this);

  @override
  String toString() => r'syncConflictEventsProvider';
}

@ProviderFor(syncConflictCount)
final syncConflictCountProvider = SyncConflictCountFamily._();

final class SyncConflictCountProvider
    extends $FunctionalProvider<AsyncValue<int>, int, FutureOr<int>>
    with $FutureModifier<int>, $FutureProvider<int> {
  SyncConflictCountProvider._({
    required SyncConflictCountFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'syncConflictCountProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$syncConflictCountHash();

  @override
  String toString() {
    return r'syncConflictCountProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<int> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<int> create(Ref ref) {
    final argument = this.argument as String;
    return syncConflictCount(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is SyncConflictCountProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$syncConflictCountHash() => r'00b41fa1d06bc55e3cd4e4fc9dc7f1a8f6f92509';

final class SyncConflictCountFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<int>, String> {
  SyncConflictCountFamily._()
    : super(
        retry: null,
        name: r'syncConflictCountProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  SyncConflictCountProvider call(String projectId) =>
      SyncConflictCountProvider._(argument: projectId, from: this);

  @override
  String toString() => r'syncConflictCountProvider';
}

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sync_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(syncStateStore)
final syncStateStoreProvider = SyncStateStoreProvider._();

final class SyncStateStoreProvider
    extends $FunctionalProvider<SyncStateStore, SyncStateStore, SyncStateStore>
    with $Provider<SyncStateStore> {
  SyncStateStoreProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'syncStateStoreProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$syncStateStoreHash();

  @$internal
  @override
  $ProviderElement<SyncStateStore> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  SyncStateStore create(Ref ref) {
    return syncStateStore(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SyncStateStore value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SyncStateStore>(value),
    );
  }
}

String _$syncStateStoreHash() => r'45a8320725186e072dc9d708571c2d4fc38268aa';

/// Runs sync and holds its status.
///
/// **Nothing that reads local data waits on this.** Every screen reads SQLite
/// through the existing repositories; this provider is watched only by the
/// status UI and the manual button. A sync in flight, failing, or permanently
/// impossible changes nothing about whether the app works.

@ProviderFor(SyncController)
final syncControllerProvider = SyncControllerProvider._();

/// Runs sync and holds its status.
///
/// **Nothing that reads local data waits on this.** Every screen reads SQLite
/// through the existing repositories; this provider is watched only by the
/// status UI and the manual button. A sync in flight, failing, or permanently
/// impossible changes nothing about whether the app works.
final class SyncControllerProvider
    extends $AsyncNotifierProvider<SyncController, SyncStatus> {
  /// Runs sync and holds its status.
  ///
  /// **Nothing that reads local data waits on this.** Every screen reads SQLite
  /// through the existing repositories; this provider is watched only by the
  /// status UI and the manual button. A sync in flight, failing, or permanently
  /// impossible changes nothing about whether the app works.
  SyncControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'syncControllerProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$syncControllerHash();

  @$internal
  @override
  SyncController create() => SyncController();
}

String _$syncControllerHash() => r'35f8ed05ffd69a5e3373e7c97fb93e94e24519b4';

/// Runs sync and holds its status.
///
/// **Nothing that reads local data waits on this.** Every screen reads SQLite
/// through the existing repositories; this provider is watched only by the
/// status UI and the manual button. A sync in flight, failing, or permanently
/// impossible changes nothing about whether the app works.

abstract class _$SyncController extends $AsyncNotifier<SyncStatus> {
  FutureOr<SyncStatus> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<SyncStatus>, SyncStatus>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<SyncStatus>, SyncStatus>,
              AsyncValue<SyncStatus>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

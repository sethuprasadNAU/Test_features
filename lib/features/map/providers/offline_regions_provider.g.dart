// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'offline_regions_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The current offline-coverage manifest — what map tiles / DEM tiles are
/// actually on disk, reconciled against disk truth on every load so the
/// coverage overlays on [OfflineDataMapScreen] never lie about what's really
/// downloaded.
///
/// Rebuilds whenever a [DownloadJob] reaches (or leaves) a terminal state —
/// watched via a `.select` on [downloadManagerProvider] so a job's frequent
/// `done`/`total` progress ticks don't each trigger a disk reconcile, only an
/// actual completion/failure/cancellation does. Screens should also call
/// `ref.invalidate(offlineRegionsProvider)` directly after a manual delete.

@ProviderFor(OfflineRegions)
final offlineRegionsProvider = OfflineRegionsProvider._();

/// The current offline-coverage manifest — what map tiles / DEM tiles are
/// actually on disk, reconciled against disk truth on every load so the
/// coverage overlays on [OfflineDataMapScreen] never lie about what's really
/// downloaded.
///
/// Rebuilds whenever a [DownloadJob] reaches (or leaves) a terminal state —
/// watched via a `.select` on [downloadManagerProvider] so a job's frequent
/// `done`/`total` progress ticks don't each trigger a disk reconcile, only an
/// actual completion/failure/cancellation does. Screens should also call
/// `ref.invalidate(offlineRegionsProvider)` directly after a manual delete.
final class OfflineRegionsProvider
    extends $AsyncNotifierProvider<OfflineRegions, List<OfflineRegion>> {
  /// The current offline-coverage manifest — what map tiles / DEM tiles are
  /// actually on disk, reconciled against disk truth on every load so the
  /// coverage overlays on [OfflineDataMapScreen] never lie about what's really
  /// downloaded.
  ///
  /// Rebuilds whenever a [DownloadJob] reaches (or leaves) a terminal state —
  /// watched via a `.select` on [downloadManagerProvider] so a job's frequent
  /// `done`/`total` progress ticks don't each trigger a disk reconcile, only an
  /// actual completion/failure/cancellation does. Screens should also call
  /// `ref.invalidate(offlineRegionsProvider)` directly after a manual delete.
  OfflineRegionsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'offlineRegionsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$offlineRegionsHash();

  @$internal
  @override
  OfflineRegions create() => OfflineRegions();
}

String _$offlineRegionsHash() => r'491cb4709616fac97a6a1f5487907009fbd993e3';

/// The current offline-coverage manifest — what map tiles / DEM tiles are
/// actually on disk, reconciled against disk truth on every load so the
/// coverage overlays on [OfflineDataMapScreen] never lie about what's really
/// downloaded.
///
/// Rebuilds whenever a [DownloadJob] reaches (or leaves) a terminal state —
/// watched via a `.select` on [downloadManagerProvider] so a job's frequent
/// `done`/`total` progress ticks don't each trigger a disk reconcile, only an
/// actual completion/failure/cancellation does. Screens should also call
/// `ref.invalidate(offlineRegionsProvider)` directly after a manual delete.

abstract class _$OfflineRegions extends $AsyncNotifier<List<OfflineRegion>> {
  FutureOr<List<OfflineRegion>> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref as $Ref<AsyncValue<List<OfflineRegion>>, List<OfflineRegion>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<List<OfflineRegion>>, List<OfflineRegion>>,
              AsyncValue<List<OfflineRegion>>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

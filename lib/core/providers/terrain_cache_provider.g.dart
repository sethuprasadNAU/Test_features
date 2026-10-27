// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'terrain_cache_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// User-configurable cap (in megabytes) on the *auto-downloaded* DEM terrain
/// cache — the elevation the viewshed tool fetches on demand for the area
/// around the observer, the same way map tiles stream in as you pan.
///
/// This is deliberately distinct from the permanent terrain backing a saved
/// offline region (Offline Data Map): that terrain is protected and never
/// evicted. Only the auto-fetched terrain is bounded by this limit, so a long
/// drive with the live viewshed on can't grow the cache without end. Persisted
/// across launches; editable on the Offline Data Map screen.

@ProviderFor(TerrainCacheLimit)
final terrainCacheLimitProvider = TerrainCacheLimitProvider._();

/// User-configurable cap (in megabytes) on the *auto-downloaded* DEM terrain
/// cache — the elevation the viewshed tool fetches on demand for the area
/// around the observer, the same way map tiles stream in as you pan.
///
/// This is deliberately distinct from the permanent terrain backing a saved
/// offline region (Offline Data Map): that terrain is protected and never
/// evicted. Only the auto-fetched terrain is bounded by this limit, so a long
/// drive with the live viewshed on can't grow the cache without end. Persisted
/// across launches; editable on the Offline Data Map screen.
final class TerrainCacheLimitProvider
    extends $AsyncNotifierProvider<TerrainCacheLimit, int> {
  /// User-configurable cap (in megabytes) on the *auto-downloaded* DEM terrain
  /// cache — the elevation the viewshed tool fetches on demand for the area
  /// around the observer, the same way map tiles stream in as you pan.
  ///
  /// This is deliberately distinct from the permanent terrain backing a saved
  /// offline region (Offline Data Map): that terrain is protected and never
  /// evicted. Only the auto-fetched terrain is bounded by this limit, so a long
  /// drive with the live viewshed on can't grow the cache without end. Persisted
  /// across launches; editable on the Offline Data Map screen.
  TerrainCacheLimitProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'terrainCacheLimitProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$terrainCacheLimitHash();

  @$internal
  @override
  TerrainCacheLimit create() => TerrainCacheLimit();
}

String _$terrainCacheLimitHash() => r'356ba3e8693e64f03826d06ec01dffbb4689a7f7';

/// User-configurable cap (in megabytes) on the *auto-downloaded* DEM terrain
/// cache — the elevation the viewshed tool fetches on demand for the area
/// around the observer, the same way map tiles stream in as you pan.
///
/// This is deliberately distinct from the permanent terrain backing a saved
/// offline region (Offline Data Map): that terrain is protected and never
/// evicted. Only the auto-fetched terrain is bounded by this limit, so a long
/// drive with the live viewshed on can't grow the cache without end. Persisted
/// across launches; editable on the Offline Data Map screen.

abstract class _$TerrainCacheLimit extends $AsyncNotifier<int> {
  FutureOr<int> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<int>, int>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<int>, int>,
              AsyncValue<int>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

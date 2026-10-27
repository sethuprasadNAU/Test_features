// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'map_settings_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The user's chosen basemap category (Terrain/Street/Satellite), persisted
/// across launches. Each category currently maps to one curated [TileSource]
/// (see [TileSources]); a future "add custom source" flow would let a user
/// override which source backs a category without changing this provider.

@ProviderFor(SelectedTileCategory)
final selectedTileCategoryProvider = SelectedTileCategoryProvider._();

/// The user's chosen basemap category (Terrain/Street/Satellite), persisted
/// across launches. Each category currently maps to one curated [TileSource]
/// (see [TileSources]); a future "add custom source" flow would let a user
/// override which source backs a category without changing this provider.
final class SelectedTileCategoryProvider
    extends $AsyncNotifierProvider<SelectedTileCategory, TileCategory> {
  /// The user's chosen basemap category (Terrain/Street/Satellite), persisted
  /// across launches. Each category currently maps to one curated [TileSource]
  /// (see [TileSources]); a future "add custom source" flow would let a user
  /// override which source backs a category without changing this provider.
  SelectedTileCategoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'selectedTileCategoryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$selectedTileCategoryHash();

  @$internal
  @override
  SelectedTileCategory create() => SelectedTileCategory();
}

String _$selectedTileCategoryHash() =>
    r'7321a958c35a7fffe7eef42a8be6a5159b3d8ba7';

/// The user's chosen basemap category (Terrain/Street/Satellite), persisted
/// across launches. Each category currently maps to one curated [TileSource]
/// (see [TileSources]); a future "add custom source" flow would let a user
/// override which source backs a category without changing this provider.

abstract class _$SelectedTileCategory extends $AsyncNotifier<TileCategory> {
  FutureOr<TileCategory> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<TileCategory>, TileCategory>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<TileCategory>, TileCategory>,
              AsyncValue<TileCategory>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// Resolves the current category to its backing [TileSource].

@ProviderFor(selectedTileSource)
final selectedTileSourceProvider = SelectedTileSourceProvider._();

/// Resolves the current category to its backing [TileSource].

final class SelectedTileSourceProvider
    extends
        $FunctionalProvider<
          AsyncValue<TileSource>,
          TileSource,
          FutureOr<TileSource>
        >
    with $FutureModifier<TileSource>, $FutureProvider<TileSource> {
  /// Resolves the current category to its backing [TileSource].
  SelectedTileSourceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'selectedTileSourceProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$selectedTileSourceHash();

  @$internal
  @override
  $FutureProviderElement<TileSource> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<TileSource> create(Ref ref) {
    return selectedTileSource(ref);
  }
}

String _$selectedTileSourceHash() =>
    r'3faa95fa190cb75160b9f12b68f044227dcd50a0';

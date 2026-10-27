import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/map/services/tile_sources.dart';

part 'map_settings_provider.g.dart';

/// The user's chosen basemap category (Terrain/Street/Satellite), persisted
/// across launches. Each category currently maps to one curated [TileSource]
/// (see [TileSources]); a future "add custom source" flow would let a user
/// override which source backs a category without changing this provider.
@riverpod
class SelectedTileCategory extends _$SelectedTileCategory {
  static const _prefsKey = 'selected_tile_category';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<TileCategory> build() async {
    final raw = await _prefs.getString(_prefsKey);
    return TileCategory.values.firstWhere(
      (c) => c.name == raw,
      orElse: () => TileCategory.terrain,
    );
  }

  Future<void> set(TileCategory category) async {
    state = AsyncData(category);
    await _prefs.setString(_prefsKey, category.name);
  }
}

/// Resolves the current category to its backing [TileSource].
@riverpod
Future<TileSource> selectedTileSource(Ref ref) async {
  final category = await ref.watch(selectedTileCategoryProvider.future);
  return TileSources.all.firstWhere((s) => s.category == category);
}

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'terrain_cache_provider.g.dart';

/// User-configurable cap (in megabytes) on the *auto-downloaded* DEM terrain
/// cache — the elevation the viewshed tool fetches on demand for the area
/// around the observer, the same way map tiles stream in as you pan.
///
/// This is deliberately distinct from the permanent terrain backing a saved
/// offline region (Offline Data Map): that terrain is protected and never
/// evicted. Only the auto-fetched terrain is bounded by this limit, so a long
/// drive with the live viewshed on can't grow the cache without end. Persisted
/// across launches; editable on the Offline Data Map screen.
@Riverpod(keepAlive: true)
class TerrainCacheLimit extends _$TerrainCacheLimit {
  static const _prefsKey = 'terrain_auto_cache_limit_mb';

  /// Reasonable default: generous enough for many days of field driving at a
  /// ~1 MB-per-disc footprint, small enough not to surprise on disk.
  static const int defaultLimitMb = 250;

  /// Don't let the cache be set so small it can't hold a single viewshed
  /// disc's worth of terrain.
  static const int minLimitMb = 25;

  final _prefs = SharedPreferencesAsync();

  @override
  Future<int> build() async {
    return await _prefs.getInt(_prefsKey) ?? defaultLimitMb;
  }

  /// Sets the cap (clamped to at least [minLimitMb]). Eviction against the new
  /// limit happens the next time terrain is auto-fetched.
  Future<void> set(int limitMb) async {
    final clamped = limitMb < minLimitMb ? minLimitMb : limitMb;
    state = AsyncData(clamped);
    await _prefs.setInt(_prefsKey, clamped);
  }
}

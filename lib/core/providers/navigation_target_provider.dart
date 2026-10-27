import 'dart:async';
import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'navigation_target_provider.g.dart';

/// A user-picked point to navigate to — either a free-tapped map location or
/// a recorded bearing/estimate/tag-location the user chose "Navigate to"
/// on. Shown as a live line + distance on the Main Map and as a bearing +
/// distance indicator on the Compass screen.
///
/// [label] is a short human-readable description of what the point is (e.g.
/// "Bearing · 7/23 14:05", "Estimated position", "Tag location") — null for a
/// free-tapped point, which callers instead show as formatted coordinates.
class NavigationTarget {
  const NavigationTarget({required this.latitude, required this.longitude, this.label});

  final double latitude;
  final double longitude;
  final String? label;

  Map<String, Object?> toJson() => {'lat': latitude, 'lon': longitude, 'label': label};

  static NavigationTarget fromJson(Map<String, Object?> json) => NavigationTarget(
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lon'] as num).toDouble(),
        label: json['label'] as String?,
      );
}

/// Persisted so a field user mid-hike doesn't lose their destination if the
/// app is backgrounded/killed — same `SharedPreferencesAsync` JSON-blob
/// pattern as `ObservationForm`/`CloudBackupSettingsNotifier`. Exactly one
/// target is active at a time; picking a new one silently replaces it
/// (confirmed with the user — matches how turn-by-turn nav apps behave).
@Riverpod(keepAlive: true)
class NavigationTargetNotifier extends _$NavigationTargetNotifier {
  static const _prefsKey = 'navigation_target_v1';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<NavigationTarget?> build() async {
    final raw = await _prefs.getString(_prefsKey);
    if (raw == null) return null;
    try {
      return NavigationTarget.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {
      return null;
    }
  }

  void set(NavigationTarget target) {
    state = AsyncData(target);
    unawaited(_prefs.setString(_prefsKey, jsonEncode(target.toJson())));
  }

  void stop() {
    state = const AsyncData(null);
    unawaited(_prefs.remove(_prefsKey));
  }
}

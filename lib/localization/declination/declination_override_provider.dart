import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'declination_override_provider.g.dart';

/// A user-set manual magnetic declination (° east positive) that overrides the
/// WMM-computed value everywhere bearings are turned into true north, or null
/// to use the computed value. Persisted so a deliberate field override sticks
/// across launches; the compass and bearing tools surface a clear badge and
/// require a confirmation whenever it's active, so it can never be forgotten.
@Riverpod(keepAlive: true)
class DeclinationOverride extends _$DeclinationOverride {
  static const _prefsKey = 'manual_declination_deg';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<double?> build() async {
    return _prefs.getDouble(_prefsKey);
  }

  /// Apply a manual declination (° east positive). Callers confirm intent with
  /// the user first (see the bearing/compass UI).
  Future<void> set(double declinationDeg) async {
    state = AsyncData(declinationDeg);
    await _prefs.setDouble(_prefsKey, declinationDeg);
  }

  /// Revert to the WMM-computed declination.
  Future<void> clear() async {
    state = const AsyncData(null);
    await _prefs.remove(_prefsKey);
  }
}

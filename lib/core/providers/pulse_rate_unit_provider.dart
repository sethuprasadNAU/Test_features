import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../format/pulse_rate_format.dart';

part 'pulse_rate_unit_provider.g.dart';

/// **One answer for the whole device, remembered across restarts** — Michael's
/// fourth answer of 2026-09-07: *"The seconds ↔ bpm toggle is remembered
/// everywhere… One setting, one answer; no screen disagreeing with another."*
///
/// It is a **device preference, not project or tag data**, and that is
/// deliberate: how a person likes to read a number is not a fact about the
/// collar, so it must not sync, must not version, and must not travel in an
/// export. The stored rate is beats per minute on every device regardless of
/// what any of them is showing.
///
/// `keepAlive: true` for the reason [TagSortOrderSetting] gives: it is read
/// from a bare `ref.read` by callers with no guaranteed listener.
@Riverpod(keepAlive: true)
class PulseRateUnitSetting extends _$PulseRateUnitSetting {
  static const _prefsKey = 'pulse_rate_unit';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<PulseRateUnit> build() async {
    final raw = await _prefs.getString(_prefsKey);
    return PulseRateUnit.values.firstWhere(
      (u) => u.name == raw,
      // The stored unit is the honest default: a person who has never chosen
      // sees the number as it is kept.
      orElse: () => PulseRateUnit.bpm,
    );
  }

  Future<void> set(PulseRateUnit unit) async {
    await _prefs.setString(_prefsKey, unit.name);
    if (!ref.mounted) return;
    state = AsyncData(unit);
  }
}

/// The chosen unit, or [PulseRateUnit.bpm] while the preference is still being
/// read off disk.
///
/// **A screen must not blank a rate for the moment it takes to load a
/// preference**, and it must not show one in a unit nobody chose either. The
/// stored unit is the safe answer to both: it is what the number actually is,
/// and the switch to seconds happens a frame later if that is what was saved.
@riverpod
PulseRateUnit pulseRateUnit(Ref ref) =>
    ref.watch(pulseRateUnitSettingProvider).value ?? PulseRateUnit.bpm;

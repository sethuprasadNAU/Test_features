/// **How a pulse rate is shown — task 11.187.**
///
/// Michael, 2026-09-07: *"I thought they were in pulses per second. Keep them
/// stored as bpm but still allow users to toggle to see them in
/// seconds-per-pulse."*
///
/// That sentence is the whole design. **Storage is beats per minute, always**,
/// so no migration ever does arithmetic on a stored value and no two devices
/// can disagree about what a number means. The choice below governs *display
/// only*, it is one setting for the whole device rather than one per screen,
/// and it survives a restart — see `PulseRateUnitSetting`.
///
/// The confusion this closes was real and it was Michael's: the number 60 on a
/// screen labelled only "pulse rate" reads as 60 of something, and the field
/// biologist counting a collar with a stopwatch is counting seconds between
/// pulses. Both readings are now sayable, and every screen says the same one.
library;

/// The two ways of saying the same rate.
enum PulseRateUnit {
  /// Beats per minute — the stored unit, and the default.
  bpm('bpm', 'Beats per minute'),

  /// Seconds between pulses: 60 ÷ bpm. What somebody with a stopwatch counts.
  secondsPerPulse('s/pulse', 'Seconds per pulse');

  const PulseRateUnit(this.suffix, this.label);

  /// The short form printed after a number.
  final String suffix;

  /// The words on the control that chooses it.
  final String label;
}

/// [bpm] expressed in [unit], as a bare number with no suffix.
///
/// Returns null for null, so a caller showing "not recorded" keeps that branch.
double? pulseRateIn(double? bpm, PulseRateUnit unit) {
  if (bpm == null) return null;
  return switch (unit) {
    PulseRateUnit.bpm => bpm,
    // A stored rate is bounded `> 0` (`NumericBound.positiveMeasurement`), so
    // this cannot divide by zero on anything the row validator let through.
    // Guarded anyway: a value that reached the screen through some path that
    // did not validate should print nothing rather than "Infinity".
    PulseRateUnit.secondsPerPulse => bpm <= 0 ? null : 60 / bpm,
  };
}

/// A rate typed in [unit], converted back to the stored unit.
///
/// The inverse of [pulseRateIn], and the reason the tag form can offer a field
/// in whichever unit the person chose without the *stored* number ever leaving
/// beats per minute.
double? pulseRateToBpm(double? value, PulseRateUnit unit) {
  if (value == null) return null;
  return switch (unit) {
    PulseRateUnit.bpm => value,
    PulseRateUnit.secondsPerPulse => value <= 0 ? null : 60 / value,
  };
}

/// [bpm] as a number for display in [unit], without a suffix — "60", "0.5",
/// "1.5". Null becomes an em dash.
///
/// **Trailing zeros are trimmed** because the two units want different
/// precision and a fixed one is wrong for both: 60 bpm should not read "60.00",
/// and 0.5 s/pulse must not read "1" or "0". Two decimals is enough to
/// distinguish any rate a collar transmits at, and enough to round-trip the
/// bpm values a person is likely to type.
String formatPulseRateValue(double? bpm, PulseRateUnit unit) {
  final value = pulseRateIn(bpm, unit);
  if (value == null) return '—';
  var text = value.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}

/// [bpm] with its unit — "60 bpm", "0.5 s/pulse" — or null when there is no
/// rate to show.
///
/// **Null rather than an em dash**, because a caller usually wants to drop the
/// whole clause: `148.520 MHz · Normal` reads better than
/// `148.520 MHz · Normal — bpm`. A caller that does want a placeholder uses
/// [formatPulseRateValue], which supplies one.
String? formatPulseRate(double? bpm, PulseRateUnit unit) {
  if (pulseRateIn(bpm, unit) == null) return null;
  return '${formatPulseRateValue(bpm, unit)} ${unit.suffix}';
}

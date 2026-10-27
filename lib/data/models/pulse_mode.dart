import 'package:tritrack_sync/tritrack_sync.dart';

/// **One of a tag's pulse modes — task 11.187.**
///
/// A name somebody chose and, when anybody has measured it, a rate in beats per
/// minute. Michael, 2026-09-07: *"The user should be able to set a pulse rate
/// for each mode and name the mode… each named mode should have its own
/// rate."*
///
/// **The rate is optional and the name is not.** A mode with no name is not a
/// mode — that is how a slot is switched off — while a collar whose rate nobody
/// has counted is an ordinary collar, and the tag form has said
/// "(bpm, optional)" since it was written.
///
/// The unit is **always** beats per minute. `PulseRateUnit` governs how a rate
/// is *shown*; nothing stored is ever in another unit.
class PulseMode {
  const PulseMode({required this.slot, required this.name, this.rateBpm});

  /// 1, 2 or 3 — the number an observation records in
  /// `Observations.pulse_mode`, and the number that survives a rename.
  final int slot;

  /// The words, as somebody typed them. Never empty: [buildPulseModes] is what
  /// guarantees that.
  final String name;

  /// Beats per minute, or null when nobody has measured it.
  final double? rateBpm;

  @override
  bool operator ==(Object other) =>
      other is PulseMode &&
      other.slot == slot &&
      other.name == name &&
      other.rateBpm == rateBpm;

  @override
  int get hashCode => Object.hash(slot, name, rateBpm);

  @override
  String toString() => 'PulseMode($slot, $name, $rateBpm)';
}

/// The modes a tag (or a tag *version*) has, from its raw columns.
///
/// [slots] is the name/rate pair for each slot in order, exactly as
/// [pulseModeColumns] declares them — so a caller supplies three pairs and this
/// decides which of them are modes.
///
/// ## It can never return an empty list, and that is the whole guarantee
///
/// Michael's rule is *"up to three modes but not fewer than 1"*, and this is
/// where "not fewer than 1" is enforced rather than hoped for. A slot-1 name
/// that is null or blank yields [defaultPulseModeNames]`[0]` — which covers a
/// row written before schema v12, a row pushed by a client that predates it,
/// and a tag form that somehow saved a blank. **Null there means "never said",
/// not "switched off": slot 1 cannot be switched off.**
///
/// Slots 2 and 3 are present exactly when they are named. A rate sitting in a
/// slot with no name is **inert** — it is never read, because nothing reads a
/// rate without first having a mode to read it for. That is worth stating
/// because it is the only way the columns can disagree with each other, and the
/// disagreement is harmless in the only direction it can occur.
List<PulseMode> buildPulseModes(List<(String?, double?)> slots) {
  final modes = <PulseMode>[];
  // **Iterates the slots that exist, not the pairs it was handed.** A caller
  // that passes too few — a shorter list, an empty one — gets the same answer a
  // row of NULLs gets, because "not supplied" and "not said" are the same fact
  // about a tag. Driving the loop off `slots.length` instead would let a caller
  // produce a modeless tag by passing nothing, which is the one outcome this
  // function exists to make unreachable.
  for (var slot = 1; slot <= maxPulseModes; slot++) {
    final (rawName, rate) =
        slot <= slots.length ? slots[slot - 1] : (null, null);
    final name = rawName?.trim() ?? '';
    if (name.isEmpty) {
      // Slot 1 is the one that cannot be absent. Every other empty slot is a
      // mode the person switched off, or never turned on.
      if (slot != 1) continue;
      modes.add(
        PulseMode(slot: 1, name: defaultPulseModeNames[0], rateBpm: rate),
      );
      continue;
    }
    modes.add(PulseMode(slot: slot, name: name, rateBpm: rate));
  }
  return modes;
}

/// The mode with this [slot] among [modes], or null when that slot is not on.
///
/// **Null is the answer for a mode somebody has since switched off**, and the
/// caller must say so rather than substituting a neighbour. A bearing recorded
/// on a mode that no longer exists is still a real bearing; what it must not do
/// is start claiming to have been heard on a mode that does.
PulseMode? pulseModeAt(List<PulseMode> modes, int slot) {
  for (final mode in modes) {
    if (mode.slot == slot) return mode;
  }
  return null;
}

/// The lowest slot number not in [usedSlots], or null when all
/// [maxPulseModes] are taken. Used by the tag form's "Add mode" control.
int? nextFreePulseModeSlot(Iterable<int> usedSlots) {
  final used = usedSlots.toSet();
  for (var slot = 1; slot <= maxPulseModes; slot++) {
    if (!used.contains(slot)) return slot;
  }
  return null;
}

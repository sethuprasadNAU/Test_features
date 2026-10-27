import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'receiver_altitude_provider.g.dart';

/// How long a non-zero receiver altitude stays in force with no record
/// saved — **four hours since the last record, not since the value was set.**
/// Michael's design, 2026-09-12: a working flight keeps the value, the next
/// morning starts clean.
const Duration kReceiverAltitudeWindow = Duration(hours: 4);

/// One foot, in metres. The stored quantity is always metres; feet exist only
/// on the way in and on the way out (US altimeters read feet).
const double kMetresPerFoot = 0.3048;

/// The unit a person reads and types altitude in. **A display preference,
/// not data** — the column holds metres whatever this says.
enum AltitudeUnit {
  metres,
  feet;

  String get suffix => switch (this) {
        AltitudeUnit.metres => 'm',
        AltitudeUnit.feet => 'ft',
      };

  double toMetres(double value) =>
      this == AltitudeUnit.feet ? value * kMetresPerFoot : value;

  double fromMetres(double metres) =>
      this == AltitudeUnit.feet ? metres / kMetresPerFoot : metres;
}

/// What a typed altitude is measured from. **Only AGL is ever stored**; an
/// MSL entry is converted at the moment it is set, by subtracting the ground
/// elevation under the current position, and is refused when that ground
/// elevation is not known.
enum AltitudeReference { agl, msl }

/// The receiver's height above ground, as the record screen will write it
/// to the next observation or non-detection — plus the two things a person
/// last chose about how to enter it.
///
/// **Task 11.67.** `Observations.altitude_agl` and
/// `Non_Detections.altitude_agl` have existed since schema v1 and, until
/// this, nothing could set them: every row said `0`, which the exports
/// declined to print (task 11.30) because a zero nobody measured reads as a
/// measurement. A receiver in an aircraft at 300 m is not slightly above the
/// ground, so this is the one place the number can be set, and the rules
/// about when it stops applying live here rather than in the screen.
///
/// **Why it is not part of the observation draft.** The draft is replaced
/// wholesale by every save; this value has to outlive a save, because the
/// whole point of it is that the second bearing of a flight defaults to the
/// altitude of the first. And it must reach a no-signal record as well as a
/// bearing, so it cannot belong to one record type's form.
class ReceiverAltitudeState {
  const ReceiverAltitudeState({
    this.aglMetres = 0,
    this.lastRecordUtc,
    this.clearedFromMetres,
    this.unit = AltitudeUnit.metres,
    this.reference = AltitudeReference.agl,
  });

  /// Height above ground level, metres. **Zero means on the ground**, which
  /// is what every record has always said and what the ground case still
  /// says — there is no separate "aerial" flag (Michael, 2026-09-12:
  /// *"Altitude should say it all"*).
  final double aglMetres;

  /// The rolling clock. Set when the value is set and moved forward by every
  /// record saved while the value is non-zero. When `now` is more than
  /// [kReceiverAltitudeWindow] past this, the value lapses — see [resolve].
  final DateTime? lastRecordUtc;

  /// **Non-null while the person is owed a sentence.** The value the window
  /// cleared, kept until one record is saved (or a new value is set), so the
  /// first record screen after a lapse can say *"altitude cleared — was
  /// 300 m"* rather than quietly recording ground observations from an
  /// aircraft that has just refuelled. **A default that changes without
  /// saying so is this project's most repeated defect and it is declined on
  /// purpose here.**
  final double? clearedFromMetres;

  /// Last unit chosen, remembered. Hard-coded to neither: a US pilot reads
  /// feet off the panel, everybody else reads metres.
  final AltitudeUnit unit;

  /// Last reference chosen, remembered for the same reason.
  final AltitudeReference reference;

  /// True when the next record will be written at a non-zero altitude.
  bool get isAboveGround => aglMetres != 0;

  /// True when the first record screen after a lapse still has to say so.
  bool get noticeOwed => clearedFromMetres != null;

  /// The state as it stands at [now]: the same state if the window has not
  /// run out, and a cleared one — with [clearedFromMetres] set so the
  /// screen says so — if it has.
  ///
  /// Pure, so the four-hour rule is a function of two timestamps and can be
  /// tested as one. The notifier calls it at load, at build and at save.
  ReceiverAltitudeState resolve(DateTime now) {
    final last = lastRecordUtc;
    if (!isAboveGround || last == null) return this;
    if (now.toUtc().difference(last) <= kReceiverAltitudeWindow) return this;
    return copyWith(
      aglMetres: 0,
      clearLastRecord: true,
      clearedFromMetres: aglMetres,
    );
  }

  ReceiverAltitudeState copyWith({
    double? aglMetres,
    DateTime? lastRecordUtc,
    bool clearLastRecord = false,
    double? clearedFromMetres,
    bool clearNotice = false,
    AltitudeUnit? unit,
    AltitudeReference? reference,
  }) {
    return ReceiverAltitudeState(
      aglMetres: aglMetres ?? this.aglMetres,
      lastRecordUtc:
          clearLastRecord ? null : (lastRecordUtc ?? this.lastRecordUtc),
      clearedFromMetres:
          clearNotice ? null : (clearedFromMetres ?? this.clearedFromMetres),
      unit: unit ?? this.unit,
      reference: reference ?? this.reference,
    );
  }

  Map<String, Object?> toJson() => {
        'aglMetres': aglMetres,
        'lastRecordUtc': lastRecordUtc?.toIso8601String(),
        'clearedFromMetres': clearedFromMetres,
        'unit': unit.name,
        'reference': reference.name,
      };

  static ReceiverAltitudeState fromJson(Map<String, Object?> json) {
    final rawLast = json['lastRecordUtc'] as String?;
    return ReceiverAltitudeState(
      aglMetres: (json['aglMetres'] as num?)?.toDouble() ?? 0,
      lastRecordUtc: rawLast == null ? null : DateTime.parse(rawLast).toUtc(),
      clearedFromMetres: (json['clearedFromMetres'] as num?)?.toDouble(),
      unit: AltitudeUnit.values.firstWhere(
        (u) => u.name == json['unit'],
        orElse: () => AltitudeUnit.metres,
      ),
      reference: AltitudeReference.values.firstWhere(
        (r) => r.name == json['reference'],
        orElse: () => AltitudeReference.agl,
      ),
    );
  }
}

/// **Survives an app restart, on purpose.** Four hours spans a restart in
/// practice — a phone rebooted at a fuel stop, or the app killed in the
/// background between passes, which is exactly what iOS does to an app that
/// has been out of sight for an hour. If the value lived in memory only, a
/// restart would return it to zero with nothing said, which is the silent
/// change this design refuses. Persisting it is also what makes the
/// four-hour rule honest across a restart: [ReceiverAltitudeState.resolve]
/// runs on the stored timestamps at load, so a phone switched on the next
/// morning owes the notice rather than the value.
///
/// `keepAlive: true` for the reason `PulseRateUnitSetting` gives: the save
/// path reads it with a bare `ref.read` and nothing guarantees a listener.
@Riverpod(keepAlive: true)
class ReceiverAltitudeSetting extends _$ReceiverAltitudeSetting {
  static const _prefsKey = 'receiver_altitude_v1';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<ReceiverAltitudeState> build() async {
    final raw = await _prefs.getString(_prefsKey);
    if (raw == null) return const ReceiverAltitudeState();
    ReceiverAltitudeState stored;
    try {
      stored = ReceiverAltitudeState.fromJson(
        jsonDecode(raw) as Map<String, Object?>,
      );
    } catch (_) {
      // A corrupt preference must not stop somebody recording; the ground
      // default is the same answer a fresh install gives.
      return const ReceiverAltitudeState();
    }
    final resolved = stored.resolve(DateTime.now());
    if (!identical(resolved, stored)) await _write(resolved);
    return resolved;
  }

  Future<void> _write(ReceiverAltitudeState next) =>
      _prefs.setString(_prefsKey, jsonEncode(next.toJson()));

  /// **Every mutation starts from the resolved state**, never the stored
  /// one. Without this, a save four hours and a minute after the last one
  /// would call [recordSaved] on a value that had already lapsed and move
  /// its clock forward — resurrecting it, with the notice never shown.
  ReceiverAltitudeState get _current =>
      (state.value ?? const ReceiverAltitudeState()).resolve(DateTime.now());

  Future<void> _set(ReceiverAltitudeState next) async {
    state = AsyncData(next);
    await _write(next);
  }

  /// Applies the four-hour rule to what is held and returns the result.
  /// Called by the record screen on build and again at save, so a screen
  /// left open across the window still writes the truth.
  ReceiverAltitudeState resolveNow([DateTime? now]) {
    final current = _current;
    final resolved = current.resolve(now ?? DateTime.now());
    if (!identical(resolved, current)) _set(resolved);
    return resolved;
  }

  /// The person setting a height above ground, in metres. Starts the
  /// rolling clock and clears any notice — the value they were told about
  /// has been replaced by one they chose.
  Future<void> setAglMetres(double metres, {DateTime? now}) => _set(
        _current.copyWith(
          aglMetres: metres,
          lastRecordUtc: (now ?? DateTime.now()).toUtc(),
          clearNotice: true,
        ),
      );

  /// The person putting the receiver back on the ground themselves. No
  /// notice is owed for a change they made.
  Future<void> clear() => _set(
        _current.copyWith(
          aglMetres: 0,
          clearLastRecord: true,
          clearNotice: true,
        ),
      );

  /// A record was saved. Moves the clock while a value is in force, and
  /// retires the lapse notice: it was to be shown until one record was
  /// saved, and one has been.
  Future<void> recordSaved({DateTime? now}) {
    final current = _current;
    return _set(
      current.copyWith(
        lastRecordUtc:
            current.isAboveGround ? (now ?? DateTime.now()).toUtc() : null,
        clearLastRecord: !current.isAboveGround,
        clearNotice: true,
      ),
    );
  }

  Future<void> setUnit(AltitudeUnit unit) =>
      _set(_current.copyWith(unit: unit));

  Future<void> setReference(AltitudeReference reference) =>
      _set(_current.copyWith(reference: reference));
}

/// The state **as it stands now** — the four-hour rule applied at the moment
/// of reading — or the ground default while the preference is being read
/// off disk. The record screen must not show an altitude nobody set for the
/// frame it takes to load one, and the ground default is what a fresh
/// install would show anyway.
///
/// Resolving here rather than in the screen means a screen that rebuilds
/// after the window has run out shows the notice without anything having
/// written to disk; the write happens on the next mutation, every one of
/// which resolves first.
@riverpod
ReceiverAltitudeState receiverAltitude(Ref ref) =>
    (ref.watch(receiverAltitudeSettingProvider).value ??
            const ReceiverAltitudeState())
        .resolve(DateTime.now());

/// `300 m` or `984 ft`, whole units — what the indicator, the notice and
/// the sheet all print, so no two of them can round differently.
String formatAltitude(double metres, AltitudeUnit unit) =>
    '${unit.fromMetres(metres).round()} ${unit.suffix}';

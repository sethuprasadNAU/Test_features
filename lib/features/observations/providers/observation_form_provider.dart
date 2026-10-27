import 'dart:async';
import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tritrack_sync/tritrack_sync.dart';

part 'observation_form_provider.g.dart';

/// In-progress Observation Logging form state. Persisted to disk on every
/// change (not just in memory) so a mid-entry crash — cold hands, dying
/// battery, the classic field failure the technical doc calls out — doesn't
/// lose the draft (DD:19, TC:312: "autosave a draft observation").
class ObservationDraftState {
  const ObservationDraftState({
    this.tagId,
    this.recordType = RecordType.directional,
    this.noSignalTagIds = const [],
    this.bearingMethod = BearingMethod.peak,
    this.pulseMode = 1,
    this.signalStrength = SignalStrength.medium,
    this.signalIrregular = false,
    this.bearingQuality = BearingQuality.good,
    this.antennaType,
    this.receiverGain,
    this.notes = '',
    this.useManualPosition = false,
    this.manualLat,
    this.manualLon,
    this.bearingDeg,
    this.bearingUncertaintyDeg = 12.0,
    this.bearingCaptureMethodDb,
    this.bearingStartDeg,
    this.bearingEndDeg,
    this.ambiguousSweep = false,
    this.truthKind = GroundTruthKind.animalAndCollar,
    this.truthPrecisionM,
    this.truthPrecisionIsPrefill = false,
    this.truthPrecisionTouched = false,
  });

  final String? tagId;
  final RecordType recordType;

  /// Tags selected for a [RecordType.noSignal] non-detection (multi-select).
  final List<String> noSignalTagIds;
  final BearingMethod bearingMethod;
  /// **Which of the selected tag's pulse modes the receiver is hearing** —
  /// a slot number (task 11.187), never the mode's words.
  ///
  /// Defaults to 1 because every tag has a slot 1 and no tag is guaranteed
  /// anything else. **A tag whose modes do not include this slot is not an
  /// error state to fix here**: the Record screen resolves the draft's slot
  /// against the tag actually selected and offers that tag's first mode
  /// instead, which is what has to happen anyway when somebody spins the tag
  /// wheel onto a collar with one mode.
  final int pulseMode;
  final SignalStrength signalStrength;

  /// **Whether the person is hearing the signal itself as wrong** — irregular
  /// pulses, a stutter, a rate that does not match the collar (task 11.193).
  ///
  /// A draft-level `bool` rather than `bool?`, because on this screen the
  /// control is either in front of somebody or it is not. **The three-valued
  /// answer is made at save time**: a record type that carries a signal stores
  /// this value, and one that does not — a note, a truth point, a no-signal
  /// sweep — stores NULL, because the question was never put. See
  /// `Observation.signalIrregular`.
  ///
  /// **Cleared by a save, like every other field on this form** — [reset]
  /// replaces the whole draft, and only the tag is remembered across records
  /// (`lastObservationTagIdProvider`). That is the behaviour this flag wants
  /// anyway: one left switched on from an earlier collar would quietly mark
  /// every following record as a suspected fault.
  final bool signalIrregular;
  final BearingQuality bearingQuality;
  final String? antennaType;
  final double? receiverGain;
  final String notes;
  final bool useManualPosition;
  final double? manualLat;
  final double? manualLon;

  /// The resolved magnetic bearing — from either the compass capture or a
  /// typed/sighted manual entry. Manual entry must stay first-class, not a
  /// fallback (TC:200, TC:209): the normal field posture (holding a metal
  /// antenna) corrupts the magnetometer.
  final double? bearingDeg;
  final double bearingUncertaintyDeg;

  /// [BearingCaptureMethod.db] string, or null when the bearing was typed by
  /// hand rather than captured from the compass.
  final String? bearingCaptureMethodDb;
  final double? bearingStartDeg;
  final double? bearingEndDeg;
  final bool ambiguousSweep;

  /// Task 11.33: what was found at a ground-truth point.
  ///
  /// Defaults to [GroundTruthKind.animalAndCollar] because that is the only
  /// kind that validates the triangulation of a live collared animal, and so
  /// the only one an accuracy statistic can count without qualification — the
  /// other two are the deliberate exceptions somebody chooses.
  final GroundTruthKind truthKind;

  /// The radial precision, in metres, claimed for a ground-truth point.
  ///
  /// Null means "nothing entered yet", and a truth point cannot be saved that
  /// way: `uncertainty_radius` is what every accuracy statistic divides by, so
  /// there is no safe value to invent on the user's behalf.
  final double? truthPrecisionM;

  /// True while [truthPrecisionM] is the figure **the app filled in from the
  /// device's own GPS accuracy**, rather than a number the user typed.
  ///
  /// **This flag is the whole of task 11.33's over-confidence guard.** A
  /// prefilled figure describes a GPS fix and nothing else, so when the
  /// position switches to a map pin it must be taken away again rather than
  /// silently re-used to describe a pin — a pin is only as precise as the
  /// person's ability to identify the spot in the imagery, and the base map's
  /// own registration is commonly off by a few metres. A number the user
  /// typed is theirs and survives the switch.
  final bool truthPrecisionIsPrefill;

  /// True once the person has typed in the precision field **at all**,
  /// including typing it empty.
  ///
  /// **This exists because an empty field and an untouched field are different
  /// states and [truthPrecisionM] alone cannot tell them apart.** Both read as
  /// null, so the prefill below treated "the user just deleted the 4" as "there
  /// is no figure yet" and put the 4 straight back — on the next frame, before
  /// the second digit could be typed. The only way to enter 10 over a prefilled
  /// 4 was to type it as `410` and then delete the leading 4. Found by Michael
  /// on hardware, 2026-08-31.
  ///
  /// It is the same shape as every other defect this project keeps finding: a
  /// check that cannot distinguish two outcomes reports one of them as the
  /// other. The remedy is the same too — record the fact rather than infer it
  /// from a value that has two meanings.
  final bool truthPrecisionTouched;

  bool get hasBearing => bearingDeg != null;

  ObservationDraftState copyWith({
    String? tagId,
    bool clearTagId = false,
    RecordType? recordType,
    List<String>? noSignalTagIds,
    BearingMethod? bearingMethod,
    int? pulseMode,
    SignalStrength? signalStrength,
    bool? signalIrregular,
    BearingQuality? bearingQuality,
    String? antennaType,
    bool clearAntennaType = false,
    double? receiverGain,
    bool clearReceiverGain = false,
    String? notes,
    bool? useManualPosition,
    double? manualLat,
    double? manualLon,
    double? bearingDeg,
    bool clearBearing = false,
    double? bearingUncertaintyDeg,
    String? bearingCaptureMethodDb,
    double? bearingStartDeg,
    double? bearingEndDeg,
    bool? ambiguousSweep,
    GroundTruthKind? truthKind,
    double? truthPrecisionM,
    bool clearTruthPrecision = false,
    bool? truthPrecisionIsPrefill,
    bool? truthPrecisionTouched,
  }) {
    return ObservationDraftState(
      tagId: clearTagId ? null : (tagId ?? this.tagId),
      recordType: recordType ?? this.recordType,
      noSignalTagIds: noSignalTagIds ?? this.noSignalTagIds,
      bearingMethod: bearingMethod ?? this.bearingMethod,
      pulseMode: pulseMode ?? this.pulseMode,
      signalStrength: signalStrength ?? this.signalStrength,
      signalIrregular: signalIrregular ?? this.signalIrregular,
      bearingQuality: bearingQuality ?? this.bearingQuality,
      antennaType: clearAntennaType ? null : (antennaType ?? this.antennaType),
      receiverGain:
          clearReceiverGain ? null : (receiverGain ?? this.receiverGain),
      notes: notes ?? this.notes,
      useManualPosition: useManualPosition ?? this.useManualPosition,
      manualLat: manualLat ?? this.manualLat,
      manualLon: manualLon ?? this.manualLon,
      bearingDeg: clearBearing ? null : (bearingDeg ?? this.bearingDeg),
      bearingUncertaintyDeg: bearingUncertaintyDeg ?? this.bearingUncertaintyDeg,
      bearingCaptureMethodDb: clearBearing
          ? null
          : (bearingCaptureMethodDb ?? this.bearingCaptureMethodDb),
      bearingStartDeg:
          clearBearing ? null : (bearingStartDeg ?? this.bearingStartDeg),
      bearingEndDeg: clearBearing ? null : (bearingEndDeg ?? this.bearingEndDeg),
      ambiguousSweep: clearBearing ? false : (ambiguousSweep ?? this.ambiguousSweep),
      truthKind: truthKind ?? this.truthKind,
      truthPrecisionM:
          clearTruthPrecision ? null : (truthPrecisionM ?? this.truthPrecisionM),
      truthPrecisionIsPrefill: clearTruthPrecision
          ? false
          : (truthPrecisionIsPrefill ?? this.truthPrecisionIsPrefill),
      // Deliberately **not** reset by [clearTruthPrecision]: clearing the field
      // is one of the ways a person touches it, and the whole point of the flag
      // is that it outlives the value going null.
      truthPrecisionTouched:
          truthPrecisionTouched ?? this.truthPrecisionTouched,
    );
  }

  Map<String, Object?> toJson() => {
        'tagId': tagId,
        'recordType': recordType.db,
        'noSignalTagIds': noSignalTagIds,
        'bearingMethod': bearingMethod.db,
        'pulseMode': pulseMode,
        'signalStrength': signalStrength.db,
        'signalIrregular': signalIrregular,
        'bearingQuality': bearingQuality.db,
        'antennaType': antennaType,
        'receiverGain': receiverGain,
        'notes': notes,
        'useManualPosition': useManualPosition,
        'manualLat': manualLat,
        'manualLon': manualLon,
        'bearingDeg': bearingDeg,
        'bearingUncertaintyDeg': bearingUncertaintyDeg,
        'bearingCaptureMethodDb': bearingCaptureMethodDb,
        'bearingStartDeg': bearingStartDeg,
        'bearingEndDeg': bearingEndDeg,
        'ambiguousSweep': ambiguousSweep,
        'truthKind': truthKind.db,
        'truthPrecisionM': truthPrecisionM,
        'truthPrecisionIsPrefill': truthPrecisionIsPrefill,
        'truthPrecisionTouched': truthPrecisionTouched,
      };

  static ObservationDraftState fromJson(Map<String, Object?> json) {
    return ObservationDraftState(
      tagId: json['tagId'] as String?,
      recordType: RecordType.fromDb(json['recordType'] as String? ?? 'directional'),
      noSignalTagIds:
          (json['noSignalTagIds'] as List?)?.map((e) => e as String).toList() ?? const [],
      bearingMethod: BearingMethod.fromDb(json['bearingMethod'] as String),
      // A draft written by a build before schema v12 names a `signalType`
      // and no slot. Mapping it is the same transcription `pulseModeSlotOf`
      // does for a stored row — and it matters more here than it looks,
      // because the draft on disk when somebody updates the app is a half-
      // finished bearing they are standing in the field holding.
      pulseMode: (json['pulseMode'] as num?)?.toInt() ??
          (json['signalType'] is String
              ? pulseModeSlotOf(
                  legacy: SignalType.fromDb(json['signalType'] as String),
                )
              : 1),
      signalStrength: SignalStrength.fromDb(json['signalStrength'] as String),
      // Absent from a draft written before task 11.193, which reads as not
      // flagged — the same thing an untouched control says.
      signalIrregular: json['signalIrregular'] as bool? ?? false,
      bearingQuality: BearingQuality.fromDb(json['bearingQuality'] as String),
      antennaType: json['antennaType'] as String?,
      receiverGain: (json['receiverGain'] as num?)?.toDouble(),
      notes: json['notes'] as String? ?? '',
      useManualPosition: json['useManualPosition'] as bool? ?? false,
      manualLat: (json['manualLat'] as num?)?.toDouble(),
      manualLon: (json['manualLon'] as num?)?.toDouble(),
      bearingDeg: (json['bearingDeg'] as num?)?.toDouble(),
      bearingUncertaintyDeg:
          (json['bearingUncertaintyDeg'] as num?)?.toDouble() ?? 12.0,
      bearingCaptureMethodDb: json['bearingCaptureMethodDb'] as String?,
      bearingStartDeg: (json['bearingStartDeg'] as num?)?.toDouble(),
      bearingEndDeg: (json['bearingEndDeg'] as num?)?.toDouble(),
      ambiguousSweep: json['ambiguousSweep'] as bool? ?? false,
      truthKind: GroundTruthKind.fromDb(
        json['truthKind'] as String? ?? GroundTruthKind.animalAndCollar.db,
      ),
      truthPrecisionM: (json['truthPrecisionM'] as num?)?.toDouble(),
      truthPrecisionIsPrefill: json['truthPrecisionIsPrefill'] as bool? ?? false,
      truthPrecisionTouched: json['truthPrecisionTouched'] as bool? ?? false,
    );
  }
}

/// The most recently selected tag id, persisted across records and app
/// restarts. Field users usually track one individual repeatedly, so the tag
/// picker should default to the last one chosen rather than resetting to the
/// middle of the list after every save (see [ObservationForm]'s default logic
/// in the logging screen, which falls back to the middle-of-list behavior
/// when no persisted value exists or it's not in the current project).
@riverpod
class LastObservationTagId extends _$LastObservationTagId {
  static const _prefsKey = 'last_observation_tag_id';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<String?> build() => _prefs.getString(_prefsKey);

  Future<void> set(String tagId) async {
    state = AsyncData(tagId);
    await _prefs.setString(_prefsKey, tagId);
  }
}

/// How the Record screen's tag wheel is ordered — task 11.249, Michael's
/// request for a switch beside the wheel.
///
/// Two orders and no more: **by frequency**, which is how a receiver is
/// tuned and the order the wheel has always had, or **by the animal's name**,
/// which is how a person thinks about who they are looking for. The switch
/// draws them as the Tag Database and Animals icons rather than words, at
/// Michael's suggestion.
enum TagWheelSort {
  frequency,
  animal;

  static TagWheelSort parse(String? stored) => switch (stored) {
    'animal' => TagWheelSort.animal,
    _ => TagWheelSort.frequency,
  };
}

/// The chosen [TagWheelSort], persisted the same way [LastObservationTagId]
/// is: a person who sorts the wheel by animal wants it that way tomorrow, and
/// a switch that reset on every launch would be a thing to press before every
/// first bearing of the day.
@riverpod
class TagWheelSortSetting extends _$TagWheelSortSetting {
  static const _prefsKey = 'tag_wheel_sort';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<TagWheelSort> build() async =>
      TagWheelSort.parse(await _prefs.getString(_prefsKey));

  Future<void> set(TagWheelSort sort) async {
    state = AsyncData(sort);
    await _prefs.setString(_prefsKey, sort.name);
  }
}

@riverpod
class ObservationForm extends _$ObservationForm {
  static const _prefsKey = 'observation_draft_v1';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<ObservationDraftState> build() async {
    final raw = await _prefs.getString(_prefsKey);
    if (raw == null) return const ObservationDraftState();
    try {
      return ObservationDraftState.fromJson(
        jsonDecode(raw) as Map<String, Object?>,
      );
    } catch (_) {
      // A corrupt/legacy draft shouldn't block logging a new observation.
      return const ObservationDraftState();
    }
  }

  void _update(ObservationDraftState Function(ObservationDraftState) update) {
    final current = state.value ?? const ObservationDraftState();
    final next = update(current);
    state = AsyncData(next);
    unawaited(_prefs.setString(_prefsKey, jsonEncode(next.toJson())));
  }

  void setTag(String tagId) => _update((s) => s.copyWith(tagId: tagId));

  /// Clears the tag — used by a "general note (no tag)" note.
  void clearTag() => _update((s) => s.copyWith(clearTagId: true));

  void setRecordType(RecordType type) =>
      _update((s) => s.copyWith(recordType: type));

  /// Toggle a tag in the No-Signal multi-select.
  void toggleNoSignalTag(String tagId) => _update((s) {
        final next = [...s.noSignalTagIds];
        next.contains(tagId) ? next.remove(tagId) : next.add(tagId);
        return s.copyWith(noSignalTagIds: next);
      });

  void setNoSignalTags(List<String> tagIds) =>
      _update((s) => s.copyWith(noSignalTagIds: tagIds));

  void setBearingMethod(BearingMethod method) =>
      _update((s) => s.copyWith(bearingMethod: method));

  void setPulseMode(int slot) => _update((s) => s.copyWith(pulseMode: slot));

  void setSignalStrength(SignalStrength strength) =>
      _update((s) => s.copyWith(signalStrength: strength));

  void setSignalIrregular(bool irregular) =>
      _update((s) => s.copyWith(signalIrregular: irregular));

  void setBearingQuality(BearingQuality quality) =>
      _update((s) => s.copyWith(bearingQuality: quality));

  void setAntennaType(String? type) => _update(
        (s) => type == null
            ? s.copyWith(clearAntennaType: true)
            : s.copyWith(antennaType: type),
      );

  void setReceiverGain(double? gain) => _update(
        (s) => gain == null
            ? s.copyWith(clearReceiverGain: true)
            : s.copyWith(receiverGain: gain),
      );

  void setNotes(String notes) => _update((s) => s.copyWith(notes: notes));

  void setManualPosition(bool useManual, {double? lat, double? lon}) =>
      _update((s) => s.copyWith(
            useManualPosition: useManual,
            manualLat: lat,
            manualLon: lon,
          ));

  /// Applies a resolved bearing (from the compass sheet or manual entry) to
  /// the draft.
  void setBearing({
    required double bearingDeg,
    required double uncertaintyDeg,
    String? captureMethodDb,
    double? startDeg,
    double? endDeg,
    bool ambiguousSweep = false,
  }) =>
      _update((s) => s.copyWith(
            bearingDeg: bearingDeg,
            bearingUncertaintyDeg: uncertaintyDeg,
            bearingCaptureMethodDb: captureMethodDb,
            bearingStartDeg: startDeg,
            bearingEndDeg: endDeg,
            ambiguousSweep: ambiguousSweep,
          ));

  void clearBearing() => _update((s) => s.copyWith(clearBearing: true));

  void setTruthKind(GroundTruthKind kind) =>
      _update((s) => s.copyWith(truthKind: kind));

  /// **The app** filling the precision in from the device's reported GPS
  /// accuracy. Only ever called while
  /// [ObservationDraftState.truthPrecisionTouched] is false — once the person
  /// has typed in the field, the number is theirs and the app stops writing to
  /// it, empty or not.
  void prefillTruthPrecision(double metres) => _update(
    (s) => s.copyWith(
      truthPrecisionM: metres,
      truthPrecisionIsPrefill: true,
    ),
  );

  /// **The person** typing in the precision field, including typing it empty.
  ///
  /// A number they entered is theirs, including one below the device's own
  /// figure — somebody standing at the spot knows things the phone does not —
  /// and an empty field is theirs too: it means "I am about to type something
  /// else", not "there is no figure yet". Both mark the field touched, which is
  /// what stops the prefill overwriting the next keystroke.
  void enterTruthPrecision(double? metres) => _update(
    (s) => (metres == null
            ? s.copyWith(clearTruthPrecision: true)
            : s.copyWith(
                truthPrecisionM: metres,
                truthPrecisionIsPrefill: false,
              ))
        .copyWith(truthPrecisionTouched: true),
  );

  /// Taking back a figure **the app** prefilled, because the position stopped
  /// being a GPS fix.
  ///
  /// Task 11.33's over-confidence guard: a prefilled number describes a GPS fix
  /// and nothing else, so switching to a map pin must remove it rather than let
  /// it silently re-describe a pin. Leaves [truthPrecisionTouched] alone — the
  /// app withdrawing its own guess is not the person touching the field, so a
  /// later GPS fix may prefill again.
  void withdrawTruthPrecisionPrefill() =>
      _update((s) => s.copyWith(clearTruthPrecision: true));

  /// Clears the draft after a successful save.
  Future<void> reset() async {
    state = const AsyncData(ObservationDraftState());
    await _prefs.remove(_prefsKey);
  }
}

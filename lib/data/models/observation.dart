import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'sync_meta.dart';

part 'observation.freezed.dart';

/// A single telemetry observation: a directional bearing or an omnidirectional
/// detection on one tag from one observer position. Stores the full bearing
/// audit trail (magnetic + true-north + declination + WMM model) so a later
/// sign/model correction stays traceable.
///
/// `antennaType` is free-ish text (`yagi_3el`, `h_adcock`, `omni`, `other`, …)
/// rather than a closed enum, since the field set is open-ended.
@freezed
@Assert(
  'pulseMode == null || '
      'signalType == SignalType.forPulseModeSlot(pulseMode)',
  'signal_type must be the projection of pulse_mode, never an independent '
  'choice — see SignalType. A caller that sets one without the other is how '
  'the two columns come to disagree about the same bearing.',
)
abstract class Observation with _$Observation {
  const Observation._();

  const factory Observation({
    required String observationId,
    required String projectId,
    required String userId,
    // Nullable: a `note`-type observation may be a general geotagged note not
    // tied to any specific tag (schema v3 dropped the NOT NULL on tag_id).
    String? tagId,
    String? sessionId,
    required DateTime timestampLocal,
    required DateTime timestampUtc,
    required String timezoneOffset,
    required double latitude,
    required double longitude,
    double? positionAccuracyM,
    required PositionSource positionSource,
    required double elevation,
    @Default(0) double altitudeAgl,
    required ObservationType observationType,
    double? magneticBearing,
    double? trueNorthBearing,
    double? bearingUncertainty,
    BearingCaptureMethod? bearingCaptureMethod,
    BearingMethod? bearingMethod,
    double? magneticBearingStart,
    double? magneticBearingEnd,
    double? trueNorthBearingStart,
    double? trueNorthBearingEnd,
    double? magneticDeclination,
    String? wmmModelVersion,
    String? antennaType,
    double? receiverGain,
    /// **The legacy two-value projection of [pulseMode]** — the column that
    /// carried a bearing's pulse type before schema v12, kept because it is
    /// `NOT NULL` on a table that already holds records and because dropping or
    /// repurposing a column costs a `schemaMajorVersion` bump. See [SignalType]
    /// for the whole argument, and [pulseModeSlot] for how the two are read
    /// together.
    ///
    /// **On a row this build writes it is derived, not chosen** — the `@Assert`
    /// above is what makes that a refusal rather than a convention.
    required SignalType signalType,
    required SignalStrength signalStrength,
    BearingQuality? bearingQuality,
    String? notes,

    /// The `Tag_Versions` row this bearing was recorded against — what the tag
    /// read at the time, as opposed to what it reads now (task 11.32).
    ///
    /// **Null means "not recorded", never "whatever the tag says now".** A
    /// bearing that predates schema v9, one pasted from a share payload, or one
    /// whose version row has not reached this device yet all carry null, and
    /// every reader must say "not recorded" rather than substitute the tag's
    /// current values. Resolve it through `TagVersionRepository.recordedState`,
    /// which returns a `RecordedTagState` that keeps the distinction.
    String? tagVersionId,

    /// **Which of the tag's pulse modes the receiver was hearing** — a slot
    /// number, 1 to 3 (task 11.187).
    ///
    /// The mode's *identity*. Its name and rate at the time live on the
    /// `Tag_Versions` row [tagVersionId] names, so a mode that is later renamed
    /// or switched off cannot rewrite what this bearing says it was heard on.
    ///
    /// **Null is an ordinary answer**, and [pulseModeSlot] is how it is read:
    /// a record written before schema v12, a record with no tag, and a pasted
    /// replica all carry null.
    int? pulseMode,

    /// **The signal itself sounded wrong** — irregular pulses, a stutter, a
    /// rate that does not match the collar (task 11.193).
    ///
    /// Michael, 2026-09-07: *"a flag for all signal recordings — not for a weak
    /// tag, but for one that seems to be malfunctioning, such as when the
    /// inter-pulse duration is irregular."* A weak signal is
    /// [signalStrength]; a bearing you do not trust is [bearingQuality]; this
    /// is the transmitter sounding faulty.
    ///
    /// **A fact about this listening moment, never about the collar.** It is
    /// not `TagStatus.malfunction` and nothing derives one from the other —
    /// several of these are the evidence a person would later use to set that
    /// status, and setting it stays their decision.
    ///
    /// **Null means nobody was asked**, and is not the same as `false`. A row
    /// written before schema v13, a record type with no signal in it (a note, a
    /// truth point, a no-signal sweep) and a payload from an older build all
    /// carry null. `false` means a signal was recorded with the control on
    /// screen and the person did not tick it.
    ///
    /// **It withdraws nothing from analysis.** Taking a bearing out of a
    /// position estimate is `Tables.observationExclusions` (task 11.7), a
    /// deliberate act with a name on it; `AnalysisEligibility` does not read
    /// this field.
    bool? signalIrregular,
    required SyncMeta sync,
  }) = _Observation;

  /// The pulse-mode slot this record was heard on, from whichever of the two
  /// columns knows — see [pulseModeSlotOf].
  ///
  /// Total, and never null: a record always has *some* answer, because
  /// [signalType] is `NOT NULL` and maps onto slots 1 and 2. What it does not
  /// promise is that the mode still exists on the tag, or that anything on this
  /// device knows what it was called — ask `RecordedTagState` for the words.
  int get pulseModeSlot =>
      pulseModeSlotOf(storedSlot: pulseMode, legacy: signalType);

  factory Observation.fromRow(Map<String, Object?> row) => Observation(
        observationId: row['observation_id'] as String,
        projectId: row['project_id'] as String,
        userId: row['user_id'] as String,
        tagId: row['tag_id'] as String?,
        sessionId: row['session_id'] as String?,
        timestampLocal: DbCodec.decodeLocal(row['timestamp_local']),
        timestampUtc: DbCodec.decodeUtc(row['timestamp_utc']),
        timezoneOffset: row['timezone_offset'] as String,
        latitude: row['latitude'] as double,
        longitude: row['longitude'] as double,
        positionAccuracyM: row['position_accuracy_m'] as double?,
        positionSource: PositionSource.fromDb(row['position_source'] as String),
        elevation: row['elevation'] as double,
        altitudeAgl: (row['altitude_agl'] as num?)?.toDouble() ?? 0,
        observationType:
            ObservationType.fromDb(row['observation_type'] as String),
        magneticBearing: row['magnetic_bearing'] as double?,
        trueNorthBearing: row['true_north_bearing'] as double?,
        bearingUncertainty: row['bearing_uncertainty'] as double?,
        bearingCaptureMethod: row['bearing_capture_method'] == null
            ? null
            : BearingCaptureMethod.fromDb(
                row['bearing_capture_method'] as String),
        bearingMethod: row['bearing_method'] == null
            ? null
            : BearingMethod.fromDb(row['bearing_method'] as String),
        magneticBearingStart: row['magnetic_bearing_start'] as double?,
        magneticBearingEnd: row['magnetic_bearing_end'] as double?,
        trueNorthBearingStart: row['true_north_bearing_start'] as double?,
        trueNorthBearingEnd: row['true_north_bearing_end'] as double?,
        magneticDeclination: row['magnetic_declination'] as double?,
        wmmModelVersion: row['wmm_model_version'] as String?,
        antennaType: row['antenna_type'] as String?,
        receiverGain: row['receiver_gain'] as double?,
        signalType: SignalType.fromDb(row['signal_type'] as String),
        signalStrength:
            SignalStrength.fromDb(row['signal_strength'] as String),
        bearingQuality: row['bearing_quality'] == null
            ? null
            : BearingQuality.fromDb(row['bearing_quality'] as String),
        notes: row['notes'] as String?,
        tagVersionId: row['tag_version_id'] as String?,
        pulseMode: (row['pulse_mode'] as num?)?.toInt(),
        // Stored as 0/1 because SQLite has no boolean. Anything else present
        // in the column is read as "set" rather than silently as false —
        // `NumericBound.flag` is what refuses it on the wire, and a reader
        // that quietly normalised an unexpected number to false would turn a
        // flagged bearing into an unflagged one.
        signalIrregular: switch (row['signal_irregular']) {
          null => null,
          final num n => n != 0,
          final Object v => v == true,
        },
        sync: SyncMeta.fromRow(row),
      );

  Map<String, Object?> toColumns() => {
        'observation_id': observationId,
        'project_id': projectId,
        'user_id': userId,
        'tag_id': tagId,
        'session_id': sessionId,
        'timestamp_local': DbCodec.encodeLocal(timestampLocal),
        'timestamp_utc': DbCodec.encodeUtc(timestampUtc),
        'timezone_offset': timezoneOffset,
        'latitude': latitude,
        'longitude': longitude,
        'position_accuracy_m': positionAccuracyM,
        'position_source': positionSource.db,
        'elevation': elevation,
        'altitude_agl': altitudeAgl,
        'observation_type': observationType.db,
        'magnetic_bearing': magneticBearing,
        'true_north_bearing': trueNorthBearing,
        'bearing_uncertainty': bearingUncertainty,
        'bearing_capture_method': bearingCaptureMethod?.db,
        'bearing_method': bearingMethod?.db,
        'magnetic_bearing_start': magneticBearingStart,
        'magnetic_bearing_end': magneticBearingEnd,
        'true_north_bearing_start': trueNorthBearingStart,
        'true_north_bearing_end': trueNorthBearingEnd,
        'magnetic_declination': magneticDeclination,
        'wmm_model_version': wmmModelVersion,
        'antenna_type': antennaType,
        'receiver_gain': receiverGain,
        'signal_type': signalType.db,
        'signal_strength': signalStrength.db,
        'bearing_quality': bearingQuality?.db,
        'notes': notes,
        'tag_version_id': tagVersionId,
        'pulse_mode': pulseMode,
        'signal_irregular': switch (signalIrregular) {
          null => null,
          final bool b => b ? 1 : 0,
        },
        ...sync.toColumns(),
      };
}

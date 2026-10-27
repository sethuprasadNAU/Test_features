// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'observation.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$Observation {

 String get observationId; String get projectId; String get userId; String? get tagId; String? get sessionId; DateTime get timestampLocal; DateTime get timestampUtc; String get timezoneOffset; double get latitude; double get longitude; double? get positionAccuracyM; PositionSource get positionSource; double get elevation; double get altitudeAgl; ObservationType get observationType; double? get magneticBearing; double? get trueNorthBearing; double? get bearingUncertainty; BearingCaptureMethod? get bearingCaptureMethod; BearingMethod? get bearingMethod; double? get magneticBearingStart; double? get magneticBearingEnd; double? get trueNorthBearingStart; double? get trueNorthBearingEnd; double? get magneticDeclination; String? get wmmModelVersion; String? get antennaType; double? get receiverGain;/// **The legacy two-value projection of [pulseMode]** — the column that
/// carried a bearing's pulse type before schema v12, kept because it is
/// `NOT NULL` on a table that already holds records and because dropping or
/// repurposing a column costs a `schemaMajorVersion` bump. See [SignalType]
/// for the whole argument, and [pulseModeSlot] for how the two are read
/// together.
///
/// **On a row this build writes it is derived, not chosen** — the `@Assert`
/// above is what makes that a refusal rather than a convention.
 SignalType get signalType; SignalStrength get signalStrength; BearingQuality? get bearingQuality; String? get notes;/// The `Tag_Versions` row this bearing was recorded against — what the tag
/// read at the time, as opposed to what it reads now (task 11.32).
///
/// **Null means "not recorded", never "whatever the tag says now".** A
/// bearing that predates schema v9, one pasted from a share payload, or one
/// whose version row has not reached this device yet all carry null, and
/// every reader must say "not recorded" rather than substitute the tag's
/// current values. Resolve it through `TagVersionRepository.recordedState`,
/// which returns a `RecordedTagState` that keeps the distinction.
 String? get tagVersionId;/// **Which of the tag's pulse modes the receiver was hearing** — a slot
/// number, 1 to 3 (task 11.187).
///
/// The mode's *identity*. Its name and rate at the time live on the
/// `Tag_Versions` row [tagVersionId] names, so a mode that is later renamed
/// or switched off cannot rewrite what this bearing says it was heard on.
///
/// **Null is an ordinary answer**, and [pulseModeSlot] is how it is read:
/// a record written before schema v12, a record with no tag, and a pasted
/// replica all carry null.
 int? get pulseMode;/// **The signal itself sounded wrong** — irregular pulses, a stutter, a
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
 bool? get signalIrregular; SyncMeta get sync;
/// Create a copy of Observation
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ObservationCopyWith<Observation> get copyWith => _$ObservationCopyWithImpl<Observation>(this as Observation, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Observation&&(identical(other.observationId, observationId) || other.observationId == observationId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.timestampLocal, timestampLocal) || other.timestampLocal == timestampLocal)&&(identical(other.timestampUtc, timestampUtc) || other.timestampUtc == timestampUtc)&&(identical(other.timezoneOffset, timezoneOffset) || other.timezoneOffset == timezoneOffset)&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.positionAccuracyM, positionAccuracyM) || other.positionAccuracyM == positionAccuracyM)&&(identical(other.positionSource, positionSource) || other.positionSource == positionSource)&&(identical(other.elevation, elevation) || other.elevation == elevation)&&(identical(other.altitudeAgl, altitudeAgl) || other.altitudeAgl == altitudeAgl)&&(identical(other.observationType, observationType) || other.observationType == observationType)&&(identical(other.magneticBearing, magneticBearing) || other.magneticBearing == magneticBearing)&&(identical(other.trueNorthBearing, trueNorthBearing) || other.trueNorthBearing == trueNorthBearing)&&(identical(other.bearingUncertainty, bearingUncertainty) || other.bearingUncertainty == bearingUncertainty)&&(identical(other.bearingCaptureMethod, bearingCaptureMethod) || other.bearingCaptureMethod == bearingCaptureMethod)&&(identical(other.bearingMethod, bearingMethod) || other.bearingMethod == bearingMethod)&&(identical(other.magneticBearingStart, magneticBearingStart) || other.magneticBearingStart == magneticBearingStart)&&(identical(other.magneticBearingEnd, magneticBearingEnd) || other.magneticBearingEnd == magneticBearingEnd)&&(identical(other.trueNorthBearingStart, trueNorthBearingStart) || other.trueNorthBearingStart == trueNorthBearingStart)&&(identical(other.trueNorthBearingEnd, trueNorthBearingEnd) || other.trueNorthBearingEnd == trueNorthBearingEnd)&&(identical(other.magneticDeclination, magneticDeclination) || other.magneticDeclination == magneticDeclination)&&(identical(other.wmmModelVersion, wmmModelVersion) || other.wmmModelVersion == wmmModelVersion)&&(identical(other.antennaType, antennaType) || other.antennaType == antennaType)&&(identical(other.receiverGain, receiverGain) || other.receiverGain == receiverGain)&&(identical(other.signalType, signalType) || other.signalType == signalType)&&(identical(other.signalStrength, signalStrength) || other.signalStrength == signalStrength)&&(identical(other.bearingQuality, bearingQuality) || other.bearingQuality == bearingQuality)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.tagVersionId, tagVersionId) || other.tagVersionId == tagVersionId)&&(identical(other.pulseMode, pulseMode) || other.pulseMode == pulseMode)&&(identical(other.signalIrregular, signalIrregular) || other.signalIrregular == signalIrregular)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hashAll([runtimeType,observationId,projectId,userId,tagId,sessionId,timestampLocal,timestampUtc,timezoneOffset,latitude,longitude,positionAccuracyM,positionSource,elevation,altitudeAgl,observationType,magneticBearing,trueNorthBearing,bearingUncertainty,bearingCaptureMethod,bearingMethod,magneticBearingStart,magneticBearingEnd,trueNorthBearingStart,trueNorthBearingEnd,magneticDeclination,wmmModelVersion,antennaType,receiverGain,signalType,signalStrength,bearingQuality,notes,tagVersionId,pulseMode,signalIrregular,sync]);

@override
String toString() {
  return 'Observation(observationId: $observationId, projectId: $projectId, userId: $userId, tagId: $tagId, sessionId: $sessionId, timestampLocal: $timestampLocal, timestampUtc: $timestampUtc, timezoneOffset: $timezoneOffset, latitude: $latitude, longitude: $longitude, positionAccuracyM: $positionAccuracyM, positionSource: $positionSource, elevation: $elevation, altitudeAgl: $altitudeAgl, observationType: $observationType, magneticBearing: $magneticBearing, trueNorthBearing: $trueNorthBearing, bearingUncertainty: $bearingUncertainty, bearingCaptureMethod: $bearingCaptureMethod, bearingMethod: $bearingMethod, magneticBearingStart: $magneticBearingStart, magneticBearingEnd: $magneticBearingEnd, trueNorthBearingStart: $trueNorthBearingStart, trueNorthBearingEnd: $trueNorthBearingEnd, magneticDeclination: $magneticDeclination, wmmModelVersion: $wmmModelVersion, antennaType: $antennaType, receiverGain: $receiverGain, signalType: $signalType, signalStrength: $signalStrength, bearingQuality: $bearingQuality, notes: $notes, tagVersionId: $tagVersionId, pulseMode: $pulseMode, signalIrregular: $signalIrregular, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $ObservationCopyWith<$Res>  {
  factory $ObservationCopyWith(Observation value, $Res Function(Observation) _then) = _$ObservationCopyWithImpl;
@useResult
$Res call({
 String observationId, String projectId, String userId, String? tagId, String? sessionId, DateTime timestampLocal, DateTime timestampUtc, String timezoneOffset, double latitude, double longitude, double? positionAccuracyM, PositionSource positionSource, double elevation, double altitudeAgl, ObservationType observationType, double? magneticBearing, double? trueNorthBearing, double? bearingUncertainty, BearingCaptureMethod? bearingCaptureMethod, BearingMethod? bearingMethod, double? magneticBearingStart, double? magneticBearingEnd, double? trueNorthBearingStart, double? trueNorthBearingEnd, double? magneticDeclination, String? wmmModelVersion, String? antennaType, double? receiverGain, SignalType signalType, SignalStrength signalStrength, BearingQuality? bearingQuality, String? notes, String? tagVersionId, int? pulseMode, bool? signalIrregular, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$ObservationCopyWithImpl<$Res>
    implements $ObservationCopyWith<$Res> {
  _$ObservationCopyWithImpl(this._self, this._then);

  final Observation _self;
  final $Res Function(Observation) _then;

/// Create a copy of Observation
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? observationId = null,Object? projectId = null,Object? userId = null,Object? tagId = freezed,Object? sessionId = freezed,Object? timestampLocal = null,Object? timestampUtc = null,Object? timezoneOffset = null,Object? latitude = null,Object? longitude = null,Object? positionAccuracyM = freezed,Object? positionSource = null,Object? elevation = null,Object? altitudeAgl = null,Object? observationType = null,Object? magneticBearing = freezed,Object? trueNorthBearing = freezed,Object? bearingUncertainty = freezed,Object? bearingCaptureMethod = freezed,Object? bearingMethod = freezed,Object? magneticBearingStart = freezed,Object? magneticBearingEnd = freezed,Object? trueNorthBearingStart = freezed,Object? trueNorthBearingEnd = freezed,Object? magneticDeclination = freezed,Object? wmmModelVersion = freezed,Object? antennaType = freezed,Object? receiverGain = freezed,Object? signalType = null,Object? signalStrength = null,Object? bearingQuality = freezed,Object? notes = freezed,Object? tagVersionId = freezed,Object? pulseMode = freezed,Object? signalIrregular = freezed,Object? sync = null,}) {
  return _then(_self.copyWith(
observationId: null == observationId ? _self.observationId : observationId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,tagId: freezed == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String?,sessionId: freezed == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String?,timestampLocal: null == timestampLocal ? _self.timestampLocal : timestampLocal // ignore: cast_nullable_to_non_nullable
as DateTime,timestampUtc: null == timestampUtc ? _self.timestampUtc : timestampUtc // ignore: cast_nullable_to_non_nullable
as DateTime,timezoneOffset: null == timezoneOffset ? _self.timezoneOffset : timezoneOffset // ignore: cast_nullable_to_non_nullable
as String,latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,positionAccuracyM: freezed == positionAccuracyM ? _self.positionAccuracyM : positionAccuracyM // ignore: cast_nullable_to_non_nullable
as double?,positionSource: null == positionSource ? _self.positionSource : positionSource // ignore: cast_nullable_to_non_nullable
as PositionSource,elevation: null == elevation ? _self.elevation : elevation // ignore: cast_nullable_to_non_nullable
as double,altitudeAgl: null == altitudeAgl ? _self.altitudeAgl : altitudeAgl // ignore: cast_nullable_to_non_nullable
as double,observationType: null == observationType ? _self.observationType : observationType // ignore: cast_nullable_to_non_nullable
as ObservationType,magneticBearing: freezed == magneticBearing ? _self.magneticBearing : magneticBearing // ignore: cast_nullable_to_non_nullable
as double?,trueNorthBearing: freezed == trueNorthBearing ? _self.trueNorthBearing : trueNorthBearing // ignore: cast_nullable_to_non_nullable
as double?,bearingUncertainty: freezed == bearingUncertainty ? _self.bearingUncertainty : bearingUncertainty // ignore: cast_nullable_to_non_nullable
as double?,bearingCaptureMethod: freezed == bearingCaptureMethod ? _self.bearingCaptureMethod : bearingCaptureMethod // ignore: cast_nullable_to_non_nullable
as BearingCaptureMethod?,bearingMethod: freezed == bearingMethod ? _self.bearingMethod : bearingMethod // ignore: cast_nullable_to_non_nullable
as BearingMethod?,magneticBearingStart: freezed == magneticBearingStart ? _self.magneticBearingStart : magneticBearingStart // ignore: cast_nullable_to_non_nullable
as double?,magneticBearingEnd: freezed == magneticBearingEnd ? _self.magneticBearingEnd : magneticBearingEnd // ignore: cast_nullable_to_non_nullable
as double?,trueNorthBearingStart: freezed == trueNorthBearingStart ? _self.trueNorthBearingStart : trueNorthBearingStart // ignore: cast_nullable_to_non_nullable
as double?,trueNorthBearingEnd: freezed == trueNorthBearingEnd ? _self.trueNorthBearingEnd : trueNorthBearingEnd // ignore: cast_nullable_to_non_nullable
as double?,magneticDeclination: freezed == magneticDeclination ? _self.magneticDeclination : magneticDeclination // ignore: cast_nullable_to_non_nullable
as double?,wmmModelVersion: freezed == wmmModelVersion ? _self.wmmModelVersion : wmmModelVersion // ignore: cast_nullable_to_non_nullable
as String?,antennaType: freezed == antennaType ? _self.antennaType : antennaType // ignore: cast_nullable_to_non_nullable
as String?,receiverGain: freezed == receiverGain ? _self.receiverGain : receiverGain // ignore: cast_nullable_to_non_nullable
as double?,signalType: null == signalType ? _self.signalType : signalType // ignore: cast_nullable_to_non_nullable
as SignalType,signalStrength: null == signalStrength ? _self.signalStrength : signalStrength // ignore: cast_nullable_to_non_nullable
as SignalStrength,bearingQuality: freezed == bearingQuality ? _self.bearingQuality : bearingQuality // ignore: cast_nullable_to_non_nullable
as BearingQuality?,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,tagVersionId: freezed == tagVersionId ? _self.tagVersionId : tagVersionId // ignore: cast_nullable_to_non_nullable
as String?,pulseMode: freezed == pulseMode ? _self.pulseMode : pulseMode // ignore: cast_nullable_to_non_nullable
as int?,signalIrregular: freezed == signalIrregular ? _self.signalIrregular : signalIrregular // ignore: cast_nullable_to_non_nullable
as bool?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of Observation
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [Observation].
extension ObservationPatterns on Observation {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Observation value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Observation() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Observation value)  $default,){
final _that = this;
switch (_that) {
case _Observation():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Observation value)?  $default,){
final _that = this;
switch (_that) {
case _Observation() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String observationId,  String projectId,  String userId,  String? tagId,  String? sessionId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double? positionAccuracyM,  PositionSource positionSource,  double elevation,  double altitudeAgl,  ObservationType observationType,  double? magneticBearing,  double? trueNorthBearing,  double? bearingUncertainty,  BearingCaptureMethod? bearingCaptureMethod,  BearingMethod? bearingMethod,  double? magneticBearingStart,  double? magneticBearingEnd,  double? trueNorthBearingStart,  double? trueNorthBearingEnd,  double? magneticDeclination,  String? wmmModelVersion,  String? antennaType,  double? receiverGain,  SignalType signalType,  SignalStrength signalStrength,  BearingQuality? bearingQuality,  String? notes,  String? tagVersionId,  int? pulseMode,  bool? signalIrregular,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Observation() when $default != null:
return $default(_that.observationId,_that.projectId,_that.userId,_that.tagId,_that.sessionId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.positionAccuracyM,_that.positionSource,_that.elevation,_that.altitudeAgl,_that.observationType,_that.magneticBearing,_that.trueNorthBearing,_that.bearingUncertainty,_that.bearingCaptureMethod,_that.bearingMethod,_that.magneticBearingStart,_that.magneticBearingEnd,_that.trueNorthBearingStart,_that.trueNorthBearingEnd,_that.magneticDeclination,_that.wmmModelVersion,_that.antennaType,_that.receiverGain,_that.signalType,_that.signalStrength,_that.bearingQuality,_that.notes,_that.tagVersionId,_that.pulseMode,_that.signalIrregular,_that.sync);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String observationId,  String projectId,  String userId,  String? tagId,  String? sessionId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double? positionAccuracyM,  PositionSource positionSource,  double elevation,  double altitudeAgl,  ObservationType observationType,  double? magneticBearing,  double? trueNorthBearing,  double? bearingUncertainty,  BearingCaptureMethod? bearingCaptureMethod,  BearingMethod? bearingMethod,  double? magneticBearingStart,  double? magneticBearingEnd,  double? trueNorthBearingStart,  double? trueNorthBearingEnd,  double? magneticDeclination,  String? wmmModelVersion,  String? antennaType,  double? receiverGain,  SignalType signalType,  SignalStrength signalStrength,  BearingQuality? bearingQuality,  String? notes,  String? tagVersionId,  int? pulseMode,  bool? signalIrregular,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _Observation():
return $default(_that.observationId,_that.projectId,_that.userId,_that.tagId,_that.sessionId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.positionAccuracyM,_that.positionSource,_that.elevation,_that.altitudeAgl,_that.observationType,_that.magneticBearing,_that.trueNorthBearing,_that.bearingUncertainty,_that.bearingCaptureMethod,_that.bearingMethod,_that.magneticBearingStart,_that.magneticBearingEnd,_that.trueNorthBearingStart,_that.trueNorthBearingEnd,_that.magneticDeclination,_that.wmmModelVersion,_that.antennaType,_that.receiverGain,_that.signalType,_that.signalStrength,_that.bearingQuality,_that.notes,_that.tagVersionId,_that.pulseMode,_that.signalIrregular,_that.sync);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String observationId,  String projectId,  String userId,  String? tagId,  String? sessionId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double? positionAccuracyM,  PositionSource positionSource,  double elevation,  double altitudeAgl,  ObservationType observationType,  double? magneticBearing,  double? trueNorthBearing,  double? bearingUncertainty,  BearingCaptureMethod? bearingCaptureMethod,  BearingMethod? bearingMethod,  double? magneticBearingStart,  double? magneticBearingEnd,  double? trueNorthBearingStart,  double? trueNorthBearingEnd,  double? magneticDeclination,  String? wmmModelVersion,  String? antennaType,  double? receiverGain,  SignalType signalType,  SignalStrength signalStrength,  BearingQuality? bearingQuality,  String? notes,  String? tagVersionId,  int? pulseMode,  bool? signalIrregular,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _Observation() when $default != null:
return $default(_that.observationId,_that.projectId,_that.userId,_that.tagId,_that.sessionId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.positionAccuracyM,_that.positionSource,_that.elevation,_that.altitudeAgl,_that.observationType,_that.magneticBearing,_that.trueNorthBearing,_that.bearingUncertainty,_that.bearingCaptureMethod,_that.bearingMethod,_that.magneticBearingStart,_that.magneticBearingEnd,_that.trueNorthBearingStart,_that.trueNorthBearingEnd,_that.magneticDeclination,_that.wmmModelVersion,_that.antennaType,_that.receiverGain,_that.signalType,_that.signalStrength,_that.bearingQuality,_that.notes,_that.tagVersionId,_that.pulseMode,_that.signalIrregular,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _Observation extends Observation {
  const _Observation({required this.observationId, required this.projectId, required this.userId, this.tagId, this.sessionId, required this.timestampLocal, required this.timestampUtc, required this.timezoneOffset, required this.latitude, required this.longitude, this.positionAccuracyM, required this.positionSource, required this.elevation, this.altitudeAgl = 0, required this.observationType, this.magneticBearing, this.trueNorthBearing, this.bearingUncertainty, this.bearingCaptureMethod, this.bearingMethod, this.magneticBearingStart, this.magneticBearingEnd, this.trueNorthBearingStart, this.trueNorthBearingEnd, this.magneticDeclination, this.wmmModelVersion, this.antennaType, this.receiverGain, required this.signalType, required this.signalStrength, this.bearingQuality, this.notes, this.tagVersionId, this.pulseMode, this.signalIrregular, required this.sync}): super._();
  

@override final  String observationId;
@override final  String projectId;
@override final  String userId;
@override final  String? tagId;
@override final  String? sessionId;
@override final  DateTime timestampLocal;
@override final  DateTime timestampUtc;
@override final  String timezoneOffset;
@override final  double latitude;
@override final  double longitude;
@override final  double? positionAccuracyM;
@override final  PositionSource positionSource;
@override final  double elevation;
@override@JsonKey() final  double altitudeAgl;
@override final  ObservationType observationType;
@override final  double? magneticBearing;
@override final  double? trueNorthBearing;
@override final  double? bearingUncertainty;
@override final  BearingCaptureMethod? bearingCaptureMethod;
@override final  BearingMethod? bearingMethod;
@override final  double? magneticBearingStart;
@override final  double? magneticBearingEnd;
@override final  double? trueNorthBearingStart;
@override final  double? trueNorthBearingEnd;
@override final  double? magneticDeclination;
@override final  String? wmmModelVersion;
@override final  String? antennaType;
@override final  double? receiverGain;
/// **The legacy two-value projection of [pulseMode]** — the column that
/// carried a bearing's pulse type before schema v12, kept because it is
/// `NOT NULL` on a table that already holds records and because dropping or
/// repurposing a column costs a `schemaMajorVersion` bump. See [SignalType]
/// for the whole argument, and [pulseModeSlot] for how the two are read
/// together.
///
/// **On a row this build writes it is derived, not chosen** — the `@Assert`
/// above is what makes that a refusal rather than a convention.
@override final  SignalType signalType;
@override final  SignalStrength signalStrength;
@override final  BearingQuality? bearingQuality;
@override final  String? notes;
/// The `Tag_Versions` row this bearing was recorded against — what the tag
/// read at the time, as opposed to what it reads now (task 11.32).
///
/// **Null means "not recorded", never "whatever the tag says now".** A
/// bearing that predates schema v9, one pasted from a share payload, or one
/// whose version row has not reached this device yet all carry null, and
/// every reader must say "not recorded" rather than substitute the tag's
/// current values. Resolve it through `TagVersionRepository.recordedState`,
/// which returns a `RecordedTagState` that keeps the distinction.
@override final  String? tagVersionId;
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
@override final  int? pulseMode;
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
@override final  bool? signalIrregular;
@override final  SyncMeta sync;

/// Create a copy of Observation
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ObservationCopyWith<_Observation> get copyWith => __$ObservationCopyWithImpl<_Observation>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Observation&&(identical(other.observationId, observationId) || other.observationId == observationId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.timestampLocal, timestampLocal) || other.timestampLocal == timestampLocal)&&(identical(other.timestampUtc, timestampUtc) || other.timestampUtc == timestampUtc)&&(identical(other.timezoneOffset, timezoneOffset) || other.timezoneOffset == timezoneOffset)&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.positionAccuracyM, positionAccuracyM) || other.positionAccuracyM == positionAccuracyM)&&(identical(other.positionSource, positionSource) || other.positionSource == positionSource)&&(identical(other.elevation, elevation) || other.elevation == elevation)&&(identical(other.altitudeAgl, altitudeAgl) || other.altitudeAgl == altitudeAgl)&&(identical(other.observationType, observationType) || other.observationType == observationType)&&(identical(other.magneticBearing, magneticBearing) || other.magneticBearing == magneticBearing)&&(identical(other.trueNorthBearing, trueNorthBearing) || other.trueNorthBearing == trueNorthBearing)&&(identical(other.bearingUncertainty, bearingUncertainty) || other.bearingUncertainty == bearingUncertainty)&&(identical(other.bearingCaptureMethod, bearingCaptureMethod) || other.bearingCaptureMethod == bearingCaptureMethod)&&(identical(other.bearingMethod, bearingMethod) || other.bearingMethod == bearingMethod)&&(identical(other.magneticBearingStart, magneticBearingStart) || other.magneticBearingStart == magneticBearingStart)&&(identical(other.magneticBearingEnd, magneticBearingEnd) || other.magneticBearingEnd == magneticBearingEnd)&&(identical(other.trueNorthBearingStart, trueNorthBearingStart) || other.trueNorthBearingStart == trueNorthBearingStart)&&(identical(other.trueNorthBearingEnd, trueNorthBearingEnd) || other.trueNorthBearingEnd == trueNorthBearingEnd)&&(identical(other.magneticDeclination, magneticDeclination) || other.magneticDeclination == magneticDeclination)&&(identical(other.wmmModelVersion, wmmModelVersion) || other.wmmModelVersion == wmmModelVersion)&&(identical(other.antennaType, antennaType) || other.antennaType == antennaType)&&(identical(other.receiverGain, receiverGain) || other.receiverGain == receiverGain)&&(identical(other.signalType, signalType) || other.signalType == signalType)&&(identical(other.signalStrength, signalStrength) || other.signalStrength == signalStrength)&&(identical(other.bearingQuality, bearingQuality) || other.bearingQuality == bearingQuality)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.tagVersionId, tagVersionId) || other.tagVersionId == tagVersionId)&&(identical(other.pulseMode, pulseMode) || other.pulseMode == pulseMode)&&(identical(other.signalIrregular, signalIrregular) || other.signalIrregular == signalIrregular)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hashAll([runtimeType,observationId,projectId,userId,tagId,sessionId,timestampLocal,timestampUtc,timezoneOffset,latitude,longitude,positionAccuracyM,positionSource,elevation,altitudeAgl,observationType,magneticBearing,trueNorthBearing,bearingUncertainty,bearingCaptureMethod,bearingMethod,magneticBearingStart,magneticBearingEnd,trueNorthBearingStart,trueNorthBearingEnd,magneticDeclination,wmmModelVersion,antennaType,receiverGain,signalType,signalStrength,bearingQuality,notes,tagVersionId,pulseMode,signalIrregular,sync]);

@override
String toString() {
  return 'Observation(observationId: $observationId, projectId: $projectId, userId: $userId, tagId: $tagId, sessionId: $sessionId, timestampLocal: $timestampLocal, timestampUtc: $timestampUtc, timezoneOffset: $timezoneOffset, latitude: $latitude, longitude: $longitude, positionAccuracyM: $positionAccuracyM, positionSource: $positionSource, elevation: $elevation, altitudeAgl: $altitudeAgl, observationType: $observationType, magneticBearing: $magneticBearing, trueNorthBearing: $trueNorthBearing, bearingUncertainty: $bearingUncertainty, bearingCaptureMethod: $bearingCaptureMethod, bearingMethod: $bearingMethod, magneticBearingStart: $magneticBearingStart, magneticBearingEnd: $magneticBearingEnd, trueNorthBearingStart: $trueNorthBearingStart, trueNorthBearingEnd: $trueNorthBearingEnd, magneticDeclination: $magneticDeclination, wmmModelVersion: $wmmModelVersion, antennaType: $antennaType, receiverGain: $receiverGain, signalType: $signalType, signalStrength: $signalStrength, bearingQuality: $bearingQuality, notes: $notes, tagVersionId: $tagVersionId, pulseMode: $pulseMode, signalIrregular: $signalIrregular, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$ObservationCopyWith<$Res> implements $ObservationCopyWith<$Res> {
  factory _$ObservationCopyWith(_Observation value, $Res Function(_Observation) _then) = __$ObservationCopyWithImpl;
@override @useResult
$Res call({
 String observationId, String projectId, String userId, String? tagId, String? sessionId, DateTime timestampLocal, DateTime timestampUtc, String timezoneOffset, double latitude, double longitude, double? positionAccuracyM, PositionSource positionSource, double elevation, double altitudeAgl, ObservationType observationType, double? magneticBearing, double? trueNorthBearing, double? bearingUncertainty, BearingCaptureMethod? bearingCaptureMethod, BearingMethod? bearingMethod, double? magneticBearingStart, double? magneticBearingEnd, double? trueNorthBearingStart, double? trueNorthBearingEnd, double? magneticDeclination, String? wmmModelVersion, String? antennaType, double? receiverGain, SignalType signalType, SignalStrength signalStrength, BearingQuality? bearingQuality, String? notes, String? tagVersionId, int? pulseMode, bool? signalIrregular, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$ObservationCopyWithImpl<$Res>
    implements _$ObservationCopyWith<$Res> {
  __$ObservationCopyWithImpl(this._self, this._then);

  final _Observation _self;
  final $Res Function(_Observation) _then;

/// Create a copy of Observation
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? observationId = null,Object? projectId = null,Object? userId = null,Object? tagId = freezed,Object? sessionId = freezed,Object? timestampLocal = null,Object? timestampUtc = null,Object? timezoneOffset = null,Object? latitude = null,Object? longitude = null,Object? positionAccuracyM = freezed,Object? positionSource = null,Object? elevation = null,Object? altitudeAgl = null,Object? observationType = null,Object? magneticBearing = freezed,Object? trueNorthBearing = freezed,Object? bearingUncertainty = freezed,Object? bearingCaptureMethod = freezed,Object? bearingMethod = freezed,Object? magneticBearingStart = freezed,Object? magneticBearingEnd = freezed,Object? trueNorthBearingStart = freezed,Object? trueNorthBearingEnd = freezed,Object? magneticDeclination = freezed,Object? wmmModelVersion = freezed,Object? antennaType = freezed,Object? receiverGain = freezed,Object? signalType = null,Object? signalStrength = null,Object? bearingQuality = freezed,Object? notes = freezed,Object? tagVersionId = freezed,Object? pulseMode = freezed,Object? signalIrregular = freezed,Object? sync = null,}) {
  return _then(_Observation(
observationId: null == observationId ? _self.observationId : observationId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,tagId: freezed == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String?,sessionId: freezed == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String?,timestampLocal: null == timestampLocal ? _self.timestampLocal : timestampLocal // ignore: cast_nullable_to_non_nullable
as DateTime,timestampUtc: null == timestampUtc ? _self.timestampUtc : timestampUtc // ignore: cast_nullable_to_non_nullable
as DateTime,timezoneOffset: null == timezoneOffset ? _self.timezoneOffset : timezoneOffset // ignore: cast_nullable_to_non_nullable
as String,latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,positionAccuracyM: freezed == positionAccuracyM ? _self.positionAccuracyM : positionAccuracyM // ignore: cast_nullable_to_non_nullable
as double?,positionSource: null == positionSource ? _self.positionSource : positionSource // ignore: cast_nullable_to_non_nullable
as PositionSource,elevation: null == elevation ? _self.elevation : elevation // ignore: cast_nullable_to_non_nullable
as double,altitudeAgl: null == altitudeAgl ? _self.altitudeAgl : altitudeAgl // ignore: cast_nullable_to_non_nullable
as double,observationType: null == observationType ? _self.observationType : observationType // ignore: cast_nullable_to_non_nullable
as ObservationType,magneticBearing: freezed == magneticBearing ? _self.magneticBearing : magneticBearing // ignore: cast_nullable_to_non_nullable
as double?,trueNorthBearing: freezed == trueNorthBearing ? _self.trueNorthBearing : trueNorthBearing // ignore: cast_nullable_to_non_nullable
as double?,bearingUncertainty: freezed == bearingUncertainty ? _self.bearingUncertainty : bearingUncertainty // ignore: cast_nullable_to_non_nullable
as double?,bearingCaptureMethod: freezed == bearingCaptureMethod ? _self.bearingCaptureMethod : bearingCaptureMethod // ignore: cast_nullable_to_non_nullable
as BearingCaptureMethod?,bearingMethod: freezed == bearingMethod ? _self.bearingMethod : bearingMethod // ignore: cast_nullable_to_non_nullable
as BearingMethod?,magneticBearingStart: freezed == magneticBearingStart ? _self.magneticBearingStart : magneticBearingStart // ignore: cast_nullable_to_non_nullable
as double?,magneticBearingEnd: freezed == magneticBearingEnd ? _self.magneticBearingEnd : magneticBearingEnd // ignore: cast_nullable_to_non_nullable
as double?,trueNorthBearingStart: freezed == trueNorthBearingStart ? _self.trueNorthBearingStart : trueNorthBearingStart // ignore: cast_nullable_to_non_nullable
as double?,trueNorthBearingEnd: freezed == trueNorthBearingEnd ? _self.trueNorthBearingEnd : trueNorthBearingEnd // ignore: cast_nullable_to_non_nullable
as double?,magneticDeclination: freezed == magneticDeclination ? _self.magneticDeclination : magneticDeclination // ignore: cast_nullable_to_non_nullable
as double?,wmmModelVersion: freezed == wmmModelVersion ? _self.wmmModelVersion : wmmModelVersion // ignore: cast_nullable_to_non_nullable
as String?,antennaType: freezed == antennaType ? _self.antennaType : antennaType // ignore: cast_nullable_to_non_nullable
as String?,receiverGain: freezed == receiverGain ? _self.receiverGain : receiverGain // ignore: cast_nullable_to_non_nullable
as double?,signalType: null == signalType ? _self.signalType : signalType // ignore: cast_nullable_to_non_nullable
as SignalType,signalStrength: null == signalStrength ? _self.signalStrength : signalStrength // ignore: cast_nullable_to_non_nullable
as SignalStrength,bearingQuality: freezed == bearingQuality ? _self.bearingQuality : bearingQuality // ignore: cast_nullable_to_non_nullable
as BearingQuality?,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,tagVersionId: freezed == tagVersionId ? _self.tagVersionId : tagVersionId // ignore: cast_nullable_to_non_nullable
as String?,pulseMode: freezed == pulseMode ? _self.pulseMode : pulseMode // ignore: cast_nullable_to_non_nullable
as int?,signalIrregular: freezed == signalIrregular ? _self.signalIrregular : signalIrregular // ignore: cast_nullable_to_non_nullable
as bool?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of Observation
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}

// dart format on

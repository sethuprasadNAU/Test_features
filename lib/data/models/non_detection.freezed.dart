// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'non_detection.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$NonDetection {

 String get nonDetectionId; String get projectId; String get userId; DateTime get timestampLocal; DateTime get timestampUtc; String get timezoneOffset; double get latitude; double get longitude; double? get positionAccuracyM; PositionSource get positionSource; double get elevation; double get altitudeAgl; List<String> get tagIdsListenedFor; String? get notes; SyncMeta get sync;
/// Create a copy of NonDetection
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$NonDetectionCopyWith<NonDetection> get copyWith => _$NonDetectionCopyWithImpl<NonDetection>(this as NonDetection, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is NonDetection&&(identical(other.nonDetectionId, nonDetectionId) || other.nonDetectionId == nonDetectionId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.timestampLocal, timestampLocal) || other.timestampLocal == timestampLocal)&&(identical(other.timestampUtc, timestampUtc) || other.timestampUtc == timestampUtc)&&(identical(other.timezoneOffset, timezoneOffset) || other.timezoneOffset == timezoneOffset)&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.positionAccuracyM, positionAccuracyM) || other.positionAccuracyM == positionAccuracyM)&&(identical(other.positionSource, positionSource) || other.positionSource == positionSource)&&(identical(other.elevation, elevation) || other.elevation == elevation)&&(identical(other.altitudeAgl, altitudeAgl) || other.altitudeAgl == altitudeAgl)&&const DeepCollectionEquality().equals(other.tagIdsListenedFor, tagIdsListenedFor)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,nonDetectionId,projectId,userId,timestampLocal,timestampUtc,timezoneOffset,latitude,longitude,positionAccuracyM,positionSource,elevation,altitudeAgl,const DeepCollectionEquality().hash(tagIdsListenedFor),notes,sync);

@override
String toString() {
  return 'NonDetection(nonDetectionId: $nonDetectionId, projectId: $projectId, userId: $userId, timestampLocal: $timestampLocal, timestampUtc: $timestampUtc, timezoneOffset: $timezoneOffset, latitude: $latitude, longitude: $longitude, positionAccuracyM: $positionAccuracyM, positionSource: $positionSource, elevation: $elevation, altitudeAgl: $altitudeAgl, tagIdsListenedFor: $tagIdsListenedFor, notes: $notes, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $NonDetectionCopyWith<$Res>  {
  factory $NonDetectionCopyWith(NonDetection value, $Res Function(NonDetection) _then) = _$NonDetectionCopyWithImpl;
@useResult
$Res call({
 String nonDetectionId, String projectId, String userId, DateTime timestampLocal, DateTime timestampUtc, String timezoneOffset, double latitude, double longitude, double? positionAccuracyM, PositionSource positionSource, double elevation, double altitudeAgl, List<String> tagIdsListenedFor, String? notes, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$NonDetectionCopyWithImpl<$Res>
    implements $NonDetectionCopyWith<$Res> {
  _$NonDetectionCopyWithImpl(this._self, this._then);

  final NonDetection _self;
  final $Res Function(NonDetection) _then;

/// Create a copy of NonDetection
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? nonDetectionId = null,Object? projectId = null,Object? userId = null,Object? timestampLocal = null,Object? timestampUtc = null,Object? timezoneOffset = null,Object? latitude = null,Object? longitude = null,Object? positionAccuracyM = freezed,Object? positionSource = null,Object? elevation = null,Object? altitudeAgl = null,Object? tagIdsListenedFor = null,Object? notes = freezed,Object? sync = null,}) {
  return _then(_self.copyWith(
nonDetectionId: null == nonDetectionId ? _self.nonDetectionId : nonDetectionId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,timestampLocal: null == timestampLocal ? _self.timestampLocal : timestampLocal // ignore: cast_nullable_to_non_nullable
as DateTime,timestampUtc: null == timestampUtc ? _self.timestampUtc : timestampUtc // ignore: cast_nullable_to_non_nullable
as DateTime,timezoneOffset: null == timezoneOffset ? _self.timezoneOffset : timezoneOffset // ignore: cast_nullable_to_non_nullable
as String,latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,positionAccuracyM: freezed == positionAccuracyM ? _self.positionAccuracyM : positionAccuracyM // ignore: cast_nullable_to_non_nullable
as double?,positionSource: null == positionSource ? _self.positionSource : positionSource // ignore: cast_nullable_to_non_nullable
as PositionSource,elevation: null == elevation ? _self.elevation : elevation // ignore: cast_nullable_to_non_nullable
as double,altitudeAgl: null == altitudeAgl ? _self.altitudeAgl : altitudeAgl // ignore: cast_nullable_to_non_nullable
as double,tagIdsListenedFor: null == tagIdsListenedFor ? _self.tagIdsListenedFor : tagIdsListenedFor // ignore: cast_nullable_to_non_nullable
as List<String>,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of NonDetection
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [NonDetection].
extension NonDetectionPatterns on NonDetection {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _NonDetection value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _NonDetection() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _NonDetection value)  $default,){
final _that = this;
switch (_that) {
case _NonDetection():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _NonDetection value)?  $default,){
final _that = this;
switch (_that) {
case _NonDetection() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String nonDetectionId,  String projectId,  String userId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double? positionAccuracyM,  PositionSource positionSource,  double elevation,  double altitudeAgl,  List<String> tagIdsListenedFor,  String? notes,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _NonDetection() when $default != null:
return $default(_that.nonDetectionId,_that.projectId,_that.userId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.positionAccuracyM,_that.positionSource,_that.elevation,_that.altitudeAgl,_that.tagIdsListenedFor,_that.notes,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String nonDetectionId,  String projectId,  String userId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double? positionAccuracyM,  PositionSource positionSource,  double elevation,  double altitudeAgl,  List<String> tagIdsListenedFor,  String? notes,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _NonDetection():
return $default(_that.nonDetectionId,_that.projectId,_that.userId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.positionAccuracyM,_that.positionSource,_that.elevation,_that.altitudeAgl,_that.tagIdsListenedFor,_that.notes,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String nonDetectionId,  String projectId,  String userId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double? positionAccuracyM,  PositionSource positionSource,  double elevation,  double altitudeAgl,  List<String> tagIdsListenedFor,  String? notes,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _NonDetection() when $default != null:
return $default(_that.nonDetectionId,_that.projectId,_that.userId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.positionAccuracyM,_that.positionSource,_that.elevation,_that.altitudeAgl,_that.tagIdsListenedFor,_that.notes,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _NonDetection extends NonDetection {
  const _NonDetection({required this.nonDetectionId, required this.projectId, required this.userId, required this.timestampLocal, required this.timestampUtc, required this.timezoneOffset, required this.latitude, required this.longitude, this.positionAccuracyM, required this.positionSource, required this.elevation, this.altitudeAgl = 0, required final  List<String> tagIdsListenedFor, this.notes, required this.sync}): _tagIdsListenedFor = tagIdsListenedFor,super._();
  

@override final  String nonDetectionId;
@override final  String projectId;
@override final  String userId;
@override final  DateTime timestampLocal;
@override final  DateTime timestampUtc;
@override final  String timezoneOffset;
@override final  double latitude;
@override final  double longitude;
@override final  double? positionAccuracyM;
@override final  PositionSource positionSource;
@override final  double elevation;
@override@JsonKey() final  double altitudeAgl;
 final  List<String> _tagIdsListenedFor;
@override List<String> get tagIdsListenedFor {
  if (_tagIdsListenedFor is EqualUnmodifiableListView) return _tagIdsListenedFor;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_tagIdsListenedFor);
}

@override final  String? notes;
@override final  SyncMeta sync;

/// Create a copy of NonDetection
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$NonDetectionCopyWith<_NonDetection> get copyWith => __$NonDetectionCopyWithImpl<_NonDetection>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _NonDetection&&(identical(other.nonDetectionId, nonDetectionId) || other.nonDetectionId == nonDetectionId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.timestampLocal, timestampLocal) || other.timestampLocal == timestampLocal)&&(identical(other.timestampUtc, timestampUtc) || other.timestampUtc == timestampUtc)&&(identical(other.timezoneOffset, timezoneOffset) || other.timezoneOffset == timezoneOffset)&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.positionAccuracyM, positionAccuracyM) || other.positionAccuracyM == positionAccuracyM)&&(identical(other.positionSource, positionSource) || other.positionSource == positionSource)&&(identical(other.elevation, elevation) || other.elevation == elevation)&&(identical(other.altitudeAgl, altitudeAgl) || other.altitudeAgl == altitudeAgl)&&const DeepCollectionEquality().equals(other._tagIdsListenedFor, _tagIdsListenedFor)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,nonDetectionId,projectId,userId,timestampLocal,timestampUtc,timezoneOffset,latitude,longitude,positionAccuracyM,positionSource,elevation,altitudeAgl,const DeepCollectionEquality().hash(_tagIdsListenedFor),notes,sync);

@override
String toString() {
  return 'NonDetection(nonDetectionId: $nonDetectionId, projectId: $projectId, userId: $userId, timestampLocal: $timestampLocal, timestampUtc: $timestampUtc, timezoneOffset: $timezoneOffset, latitude: $latitude, longitude: $longitude, positionAccuracyM: $positionAccuracyM, positionSource: $positionSource, elevation: $elevation, altitudeAgl: $altitudeAgl, tagIdsListenedFor: $tagIdsListenedFor, notes: $notes, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$NonDetectionCopyWith<$Res> implements $NonDetectionCopyWith<$Res> {
  factory _$NonDetectionCopyWith(_NonDetection value, $Res Function(_NonDetection) _then) = __$NonDetectionCopyWithImpl;
@override @useResult
$Res call({
 String nonDetectionId, String projectId, String userId, DateTime timestampLocal, DateTime timestampUtc, String timezoneOffset, double latitude, double longitude, double? positionAccuracyM, PositionSource positionSource, double elevation, double altitudeAgl, List<String> tagIdsListenedFor, String? notes, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$NonDetectionCopyWithImpl<$Res>
    implements _$NonDetectionCopyWith<$Res> {
  __$NonDetectionCopyWithImpl(this._self, this._then);

  final _NonDetection _self;
  final $Res Function(_NonDetection) _then;

/// Create a copy of NonDetection
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? nonDetectionId = null,Object? projectId = null,Object? userId = null,Object? timestampLocal = null,Object? timestampUtc = null,Object? timezoneOffset = null,Object? latitude = null,Object? longitude = null,Object? positionAccuracyM = freezed,Object? positionSource = null,Object? elevation = null,Object? altitudeAgl = null,Object? tagIdsListenedFor = null,Object? notes = freezed,Object? sync = null,}) {
  return _then(_NonDetection(
nonDetectionId: null == nonDetectionId ? _self.nonDetectionId : nonDetectionId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,timestampLocal: null == timestampLocal ? _self.timestampLocal : timestampLocal // ignore: cast_nullable_to_non_nullable
as DateTime,timestampUtc: null == timestampUtc ? _self.timestampUtc : timestampUtc // ignore: cast_nullable_to_non_nullable
as DateTime,timezoneOffset: null == timezoneOffset ? _self.timezoneOffset : timezoneOffset // ignore: cast_nullable_to_non_nullable
as String,latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,positionAccuracyM: freezed == positionAccuracyM ? _self.positionAccuracyM : positionAccuracyM // ignore: cast_nullable_to_non_nullable
as double?,positionSource: null == positionSource ? _self.positionSource : positionSource // ignore: cast_nullable_to_non_nullable
as PositionSource,elevation: null == elevation ? _self.elevation : elevation // ignore: cast_nullable_to_non_nullable
as double,altitudeAgl: null == altitudeAgl ? _self.altitudeAgl : altitudeAgl // ignore: cast_nullable_to_non_nullable
as double,tagIdsListenedFor: null == tagIdsListenedFor ? _self._tagIdsListenedFor : tagIdsListenedFor // ignore: cast_nullable_to_non_nullable
as List<String>,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of NonDetection
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

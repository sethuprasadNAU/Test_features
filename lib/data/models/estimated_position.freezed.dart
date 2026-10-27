// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'estimated_position.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$EstimatedPosition {

 String get positionId; String get projectId; String get tagId; DateTime get timestampLocal; DateTime get timestampUtc; String get timezoneOffset; double get latitude; double get longitude; double? get semiMajorAxis; double? get semiMinorAxis; double? get rotationAngle; EstimationMethod get method; List<String> get observationIdsUsed; String? get notes; SyncMeta get sync;
/// Create a copy of EstimatedPosition
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$EstimatedPositionCopyWith<EstimatedPosition> get copyWith => _$EstimatedPositionCopyWithImpl<EstimatedPosition>(this as EstimatedPosition, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is EstimatedPosition&&(identical(other.positionId, positionId) || other.positionId == positionId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.timestampLocal, timestampLocal) || other.timestampLocal == timestampLocal)&&(identical(other.timestampUtc, timestampUtc) || other.timestampUtc == timestampUtc)&&(identical(other.timezoneOffset, timezoneOffset) || other.timezoneOffset == timezoneOffset)&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.semiMajorAxis, semiMajorAxis) || other.semiMajorAxis == semiMajorAxis)&&(identical(other.semiMinorAxis, semiMinorAxis) || other.semiMinorAxis == semiMinorAxis)&&(identical(other.rotationAngle, rotationAngle) || other.rotationAngle == rotationAngle)&&(identical(other.method, method) || other.method == method)&&const DeepCollectionEquality().equals(other.observationIdsUsed, observationIdsUsed)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,positionId,projectId,tagId,timestampLocal,timestampUtc,timezoneOffset,latitude,longitude,semiMajorAxis,semiMinorAxis,rotationAngle,method,const DeepCollectionEquality().hash(observationIdsUsed),notes,sync);

@override
String toString() {
  return 'EstimatedPosition(positionId: $positionId, projectId: $projectId, tagId: $tagId, timestampLocal: $timestampLocal, timestampUtc: $timestampUtc, timezoneOffset: $timezoneOffset, latitude: $latitude, longitude: $longitude, semiMajorAxis: $semiMajorAxis, semiMinorAxis: $semiMinorAxis, rotationAngle: $rotationAngle, method: $method, observationIdsUsed: $observationIdsUsed, notes: $notes, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $EstimatedPositionCopyWith<$Res>  {
  factory $EstimatedPositionCopyWith(EstimatedPosition value, $Res Function(EstimatedPosition) _then) = _$EstimatedPositionCopyWithImpl;
@useResult
$Res call({
 String positionId, String projectId, String tagId, DateTime timestampLocal, DateTime timestampUtc, String timezoneOffset, double latitude, double longitude, double? semiMajorAxis, double? semiMinorAxis, double? rotationAngle, EstimationMethod method, List<String> observationIdsUsed, String? notes, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$EstimatedPositionCopyWithImpl<$Res>
    implements $EstimatedPositionCopyWith<$Res> {
  _$EstimatedPositionCopyWithImpl(this._self, this._then);

  final EstimatedPosition _self;
  final $Res Function(EstimatedPosition) _then;

/// Create a copy of EstimatedPosition
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? positionId = null,Object? projectId = null,Object? tagId = null,Object? timestampLocal = null,Object? timestampUtc = null,Object? timezoneOffset = null,Object? latitude = null,Object? longitude = null,Object? semiMajorAxis = freezed,Object? semiMinorAxis = freezed,Object? rotationAngle = freezed,Object? method = null,Object? observationIdsUsed = null,Object? notes = freezed,Object? sync = null,}) {
  return _then(_self.copyWith(
positionId: null == positionId ? _self.positionId : positionId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,timestampLocal: null == timestampLocal ? _self.timestampLocal : timestampLocal // ignore: cast_nullable_to_non_nullable
as DateTime,timestampUtc: null == timestampUtc ? _self.timestampUtc : timestampUtc // ignore: cast_nullable_to_non_nullable
as DateTime,timezoneOffset: null == timezoneOffset ? _self.timezoneOffset : timezoneOffset // ignore: cast_nullable_to_non_nullable
as String,latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,semiMajorAxis: freezed == semiMajorAxis ? _self.semiMajorAxis : semiMajorAxis // ignore: cast_nullable_to_non_nullable
as double?,semiMinorAxis: freezed == semiMinorAxis ? _self.semiMinorAxis : semiMinorAxis // ignore: cast_nullable_to_non_nullable
as double?,rotationAngle: freezed == rotationAngle ? _self.rotationAngle : rotationAngle // ignore: cast_nullable_to_non_nullable
as double?,method: null == method ? _self.method : method // ignore: cast_nullable_to_non_nullable
as EstimationMethod,observationIdsUsed: null == observationIdsUsed ? _self.observationIdsUsed : observationIdsUsed // ignore: cast_nullable_to_non_nullable
as List<String>,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of EstimatedPosition
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [EstimatedPosition].
extension EstimatedPositionPatterns on EstimatedPosition {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _EstimatedPosition value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _EstimatedPosition() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _EstimatedPosition value)  $default,){
final _that = this;
switch (_that) {
case _EstimatedPosition():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _EstimatedPosition value)?  $default,){
final _that = this;
switch (_that) {
case _EstimatedPosition() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String positionId,  String projectId,  String tagId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double? semiMajorAxis,  double? semiMinorAxis,  double? rotationAngle,  EstimationMethod method,  List<String> observationIdsUsed,  String? notes,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _EstimatedPosition() when $default != null:
return $default(_that.positionId,_that.projectId,_that.tagId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.semiMajorAxis,_that.semiMinorAxis,_that.rotationAngle,_that.method,_that.observationIdsUsed,_that.notes,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String positionId,  String projectId,  String tagId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double? semiMajorAxis,  double? semiMinorAxis,  double? rotationAngle,  EstimationMethod method,  List<String> observationIdsUsed,  String? notes,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _EstimatedPosition():
return $default(_that.positionId,_that.projectId,_that.tagId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.semiMajorAxis,_that.semiMinorAxis,_that.rotationAngle,_that.method,_that.observationIdsUsed,_that.notes,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String positionId,  String projectId,  String tagId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double? semiMajorAxis,  double? semiMinorAxis,  double? rotationAngle,  EstimationMethod method,  List<String> observationIdsUsed,  String? notes,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _EstimatedPosition() when $default != null:
return $default(_that.positionId,_that.projectId,_that.tagId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.semiMajorAxis,_that.semiMinorAxis,_that.rotationAngle,_that.method,_that.observationIdsUsed,_that.notes,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _EstimatedPosition extends EstimatedPosition {
  const _EstimatedPosition({required this.positionId, required this.projectId, required this.tagId, required this.timestampLocal, required this.timestampUtc, required this.timezoneOffset, required this.latitude, required this.longitude, required this.semiMajorAxis, required this.semiMinorAxis, required this.rotationAngle, required this.method, required final  List<String> observationIdsUsed, this.notes, required this.sync}): _observationIdsUsed = observationIdsUsed,super._();
  

@override final  String positionId;
@override final  String projectId;
@override final  String tagId;
@override final  DateTime timestampLocal;
@override final  DateTime timestampUtc;
@override final  String timezoneOffset;
@override final  double latitude;
@override final  double longitude;
@override final  double? semiMajorAxis;
@override final  double? semiMinorAxis;
@override final  double? rotationAngle;
@override final  EstimationMethod method;
 final  List<String> _observationIdsUsed;
@override List<String> get observationIdsUsed {
  if (_observationIdsUsed is EqualUnmodifiableListView) return _observationIdsUsed;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_observationIdsUsed);
}

@override final  String? notes;
@override final  SyncMeta sync;

/// Create a copy of EstimatedPosition
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$EstimatedPositionCopyWith<_EstimatedPosition> get copyWith => __$EstimatedPositionCopyWithImpl<_EstimatedPosition>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _EstimatedPosition&&(identical(other.positionId, positionId) || other.positionId == positionId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.timestampLocal, timestampLocal) || other.timestampLocal == timestampLocal)&&(identical(other.timestampUtc, timestampUtc) || other.timestampUtc == timestampUtc)&&(identical(other.timezoneOffset, timezoneOffset) || other.timezoneOffset == timezoneOffset)&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.semiMajorAxis, semiMajorAxis) || other.semiMajorAxis == semiMajorAxis)&&(identical(other.semiMinorAxis, semiMinorAxis) || other.semiMinorAxis == semiMinorAxis)&&(identical(other.rotationAngle, rotationAngle) || other.rotationAngle == rotationAngle)&&(identical(other.method, method) || other.method == method)&&const DeepCollectionEquality().equals(other._observationIdsUsed, _observationIdsUsed)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,positionId,projectId,tagId,timestampLocal,timestampUtc,timezoneOffset,latitude,longitude,semiMajorAxis,semiMinorAxis,rotationAngle,method,const DeepCollectionEquality().hash(_observationIdsUsed),notes,sync);

@override
String toString() {
  return 'EstimatedPosition(positionId: $positionId, projectId: $projectId, tagId: $tagId, timestampLocal: $timestampLocal, timestampUtc: $timestampUtc, timezoneOffset: $timezoneOffset, latitude: $latitude, longitude: $longitude, semiMajorAxis: $semiMajorAxis, semiMinorAxis: $semiMinorAxis, rotationAngle: $rotationAngle, method: $method, observationIdsUsed: $observationIdsUsed, notes: $notes, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$EstimatedPositionCopyWith<$Res> implements $EstimatedPositionCopyWith<$Res> {
  factory _$EstimatedPositionCopyWith(_EstimatedPosition value, $Res Function(_EstimatedPosition) _then) = __$EstimatedPositionCopyWithImpl;
@override @useResult
$Res call({
 String positionId, String projectId, String tagId, DateTime timestampLocal, DateTime timestampUtc, String timezoneOffset, double latitude, double longitude, double? semiMajorAxis, double? semiMinorAxis, double? rotationAngle, EstimationMethod method, List<String> observationIdsUsed, String? notes, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$EstimatedPositionCopyWithImpl<$Res>
    implements _$EstimatedPositionCopyWith<$Res> {
  __$EstimatedPositionCopyWithImpl(this._self, this._then);

  final _EstimatedPosition _self;
  final $Res Function(_EstimatedPosition) _then;

/// Create a copy of EstimatedPosition
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? positionId = null,Object? projectId = null,Object? tagId = null,Object? timestampLocal = null,Object? timestampUtc = null,Object? timezoneOffset = null,Object? latitude = null,Object? longitude = null,Object? semiMajorAxis = freezed,Object? semiMinorAxis = freezed,Object? rotationAngle = freezed,Object? method = null,Object? observationIdsUsed = null,Object? notes = freezed,Object? sync = null,}) {
  return _then(_EstimatedPosition(
positionId: null == positionId ? _self.positionId : positionId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,timestampLocal: null == timestampLocal ? _self.timestampLocal : timestampLocal // ignore: cast_nullable_to_non_nullable
as DateTime,timestampUtc: null == timestampUtc ? _self.timestampUtc : timestampUtc // ignore: cast_nullable_to_non_nullable
as DateTime,timezoneOffset: null == timezoneOffset ? _self.timezoneOffset : timezoneOffset // ignore: cast_nullable_to_non_nullable
as String,latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,semiMajorAxis: freezed == semiMajorAxis ? _self.semiMajorAxis : semiMajorAxis // ignore: cast_nullable_to_non_nullable
as double?,semiMinorAxis: freezed == semiMinorAxis ? _self.semiMinorAxis : semiMinorAxis // ignore: cast_nullable_to_non_nullable
as double?,rotationAngle: freezed == rotationAngle ? _self.rotationAngle : rotationAngle // ignore: cast_nullable_to_non_nullable
as double?,method: null == method ? _self.method : method // ignore: cast_nullable_to_non_nullable
as EstimationMethod,observationIdsUsed: null == observationIdsUsed ? _self._observationIdsUsed : observationIdsUsed // ignore: cast_nullable_to_non_nullable
as List<String>,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of EstimatedPosition
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

// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'actual_tag_location.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ActualTagLocation {

 String get locationId; String get projectId; String get tagId; DateTime get timestampLocal; DateTime get timestampUtc; String get timezoneOffset; double get latitude; double get longitude; double get uncertaintyRadius; String? get notes;/// Whether the animal, the collar, or both were found here (task 11.33).
///
/// Null only on a row written before schema v10, where it reads as "not
/// recorded" — every point this app writes sets it. Anything computing
/// accuracy statistics must read it: only [GroundTruthKind.animalAndCollar]
/// validates the triangulation of a live collared animal.
 GroundTruthKind? get foundKind;/// The `Tag_Versions` row the tag read when this point was taken — what the
/// receiver was tuned to and what the collar was called at the time (task
/// 11.32's rule, applied here by task 11.33).
///
/// Null is an ordinary answer: a tag with no version history yet, or a row
/// written before schema v10. Editing the tag afterwards cannot change it,
/// which is what lets an export made after a rename still be matched to the
/// animal it describes.
 String? get tagVersionId;/// **Who walked in and found it** (task 11.93).
///
/// Null only on a row written before schema v11, where it reads as "not
/// recorded" — every point this app writes sets it to the person who
/// saved it. It is deliberately not [SyncMeta.lastModifiedBy], which names
/// whoever last *touched* the row: a colleague who corrects the precision
/// figure has not become the person who found the collar.
///
/// **A fact about the record, not a permission.** Any contributor may
/// still edit or delete the point — `truthPointEditVerdict` does not read
/// this column and must not start to. Michael settled that on 2026-08-31:
/// the person who saw the pride and the person driving the truck may not
/// be the same person.
 String? get userId;/// How the coordinate was got: a GPS fix, a hand-placed pin, or a fix
/// somebody later nudged by hand (task 11.93).
///
/// Null only on a row written before schema v11, where it reads as "not
/// recorded". [PositionSource.gpsFixAdjusted] exists because the position
/// became editable in the same task: a point that began as a measurement
/// and was moved by hand is neither of the other two, and the precision
/// radius alone cannot say which it is.
 PositionSource? get positionSource; SyncMeta get sync;
/// Create a copy of ActualTagLocation
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ActualTagLocationCopyWith<ActualTagLocation> get copyWith => _$ActualTagLocationCopyWithImpl<ActualTagLocation>(this as ActualTagLocation, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ActualTagLocation&&(identical(other.locationId, locationId) || other.locationId == locationId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.timestampLocal, timestampLocal) || other.timestampLocal == timestampLocal)&&(identical(other.timestampUtc, timestampUtc) || other.timestampUtc == timestampUtc)&&(identical(other.timezoneOffset, timezoneOffset) || other.timezoneOffset == timezoneOffset)&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.uncertaintyRadius, uncertaintyRadius) || other.uncertaintyRadius == uncertaintyRadius)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.foundKind, foundKind) || other.foundKind == foundKind)&&(identical(other.tagVersionId, tagVersionId) || other.tagVersionId == tagVersionId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.positionSource, positionSource) || other.positionSource == positionSource)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,locationId,projectId,tagId,timestampLocal,timestampUtc,timezoneOffset,latitude,longitude,uncertaintyRadius,notes,foundKind,tagVersionId,userId,positionSource,sync);

@override
String toString() {
  return 'ActualTagLocation(locationId: $locationId, projectId: $projectId, tagId: $tagId, timestampLocal: $timestampLocal, timestampUtc: $timestampUtc, timezoneOffset: $timezoneOffset, latitude: $latitude, longitude: $longitude, uncertaintyRadius: $uncertaintyRadius, notes: $notes, foundKind: $foundKind, tagVersionId: $tagVersionId, userId: $userId, positionSource: $positionSource, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $ActualTagLocationCopyWith<$Res>  {
  factory $ActualTagLocationCopyWith(ActualTagLocation value, $Res Function(ActualTagLocation) _then) = _$ActualTagLocationCopyWithImpl;
@useResult
$Res call({
 String locationId, String projectId, String tagId, DateTime timestampLocal, DateTime timestampUtc, String timezoneOffset, double latitude, double longitude, double uncertaintyRadius, String? notes, GroundTruthKind? foundKind, String? tagVersionId, String? userId, PositionSource? positionSource, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$ActualTagLocationCopyWithImpl<$Res>
    implements $ActualTagLocationCopyWith<$Res> {
  _$ActualTagLocationCopyWithImpl(this._self, this._then);

  final ActualTagLocation _self;
  final $Res Function(ActualTagLocation) _then;

/// Create a copy of ActualTagLocation
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? locationId = null,Object? projectId = null,Object? tagId = null,Object? timestampLocal = null,Object? timestampUtc = null,Object? timezoneOffset = null,Object? latitude = null,Object? longitude = null,Object? uncertaintyRadius = null,Object? notes = freezed,Object? foundKind = freezed,Object? tagVersionId = freezed,Object? userId = freezed,Object? positionSource = freezed,Object? sync = null,}) {
  return _then(_self.copyWith(
locationId: null == locationId ? _self.locationId : locationId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,timestampLocal: null == timestampLocal ? _self.timestampLocal : timestampLocal // ignore: cast_nullable_to_non_nullable
as DateTime,timestampUtc: null == timestampUtc ? _self.timestampUtc : timestampUtc // ignore: cast_nullable_to_non_nullable
as DateTime,timezoneOffset: null == timezoneOffset ? _self.timezoneOffset : timezoneOffset // ignore: cast_nullable_to_non_nullable
as String,latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,uncertaintyRadius: null == uncertaintyRadius ? _self.uncertaintyRadius : uncertaintyRadius // ignore: cast_nullable_to_non_nullable
as double,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,foundKind: freezed == foundKind ? _self.foundKind : foundKind // ignore: cast_nullable_to_non_nullable
as GroundTruthKind?,tagVersionId: freezed == tagVersionId ? _self.tagVersionId : tagVersionId // ignore: cast_nullable_to_non_nullable
as String?,userId: freezed == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String?,positionSource: freezed == positionSource ? _self.positionSource : positionSource // ignore: cast_nullable_to_non_nullable
as PositionSource?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of ActualTagLocation
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [ActualTagLocation].
extension ActualTagLocationPatterns on ActualTagLocation {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ActualTagLocation value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ActualTagLocation() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ActualTagLocation value)  $default,){
final _that = this;
switch (_that) {
case _ActualTagLocation():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ActualTagLocation value)?  $default,){
final _that = this;
switch (_that) {
case _ActualTagLocation() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String locationId,  String projectId,  String tagId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double uncertaintyRadius,  String? notes,  GroundTruthKind? foundKind,  String? tagVersionId,  String? userId,  PositionSource? positionSource,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ActualTagLocation() when $default != null:
return $default(_that.locationId,_that.projectId,_that.tagId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.uncertaintyRadius,_that.notes,_that.foundKind,_that.tagVersionId,_that.userId,_that.positionSource,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String locationId,  String projectId,  String tagId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double uncertaintyRadius,  String? notes,  GroundTruthKind? foundKind,  String? tagVersionId,  String? userId,  PositionSource? positionSource,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _ActualTagLocation():
return $default(_that.locationId,_that.projectId,_that.tagId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.uncertaintyRadius,_that.notes,_that.foundKind,_that.tagVersionId,_that.userId,_that.positionSource,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String locationId,  String projectId,  String tagId,  DateTime timestampLocal,  DateTime timestampUtc,  String timezoneOffset,  double latitude,  double longitude,  double uncertaintyRadius,  String? notes,  GroundTruthKind? foundKind,  String? tagVersionId,  String? userId,  PositionSource? positionSource,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _ActualTagLocation() when $default != null:
return $default(_that.locationId,_that.projectId,_that.tagId,_that.timestampLocal,_that.timestampUtc,_that.timezoneOffset,_that.latitude,_that.longitude,_that.uncertaintyRadius,_that.notes,_that.foundKind,_that.tagVersionId,_that.userId,_that.positionSource,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _ActualTagLocation extends ActualTagLocation {
  const _ActualTagLocation({required this.locationId, required this.projectId, required this.tagId, required this.timestampLocal, required this.timestampUtc, required this.timezoneOffset, required this.latitude, required this.longitude, required this.uncertaintyRadius, this.notes, this.foundKind, this.tagVersionId, this.userId, this.positionSource, required this.sync}): super._();
  

@override final  String locationId;
@override final  String projectId;
@override final  String tagId;
@override final  DateTime timestampLocal;
@override final  DateTime timestampUtc;
@override final  String timezoneOffset;
@override final  double latitude;
@override final  double longitude;
@override final  double uncertaintyRadius;
@override final  String? notes;
/// Whether the animal, the collar, or both were found here (task 11.33).
///
/// Null only on a row written before schema v10, where it reads as "not
/// recorded" — every point this app writes sets it. Anything computing
/// accuracy statistics must read it: only [GroundTruthKind.animalAndCollar]
/// validates the triangulation of a live collared animal.
@override final  GroundTruthKind? foundKind;
/// The `Tag_Versions` row the tag read when this point was taken — what the
/// receiver was tuned to and what the collar was called at the time (task
/// 11.32's rule, applied here by task 11.33).
///
/// Null is an ordinary answer: a tag with no version history yet, or a row
/// written before schema v10. Editing the tag afterwards cannot change it,
/// which is what lets an export made after a rename still be matched to the
/// animal it describes.
@override final  String? tagVersionId;
/// **Who walked in and found it** (task 11.93).
///
/// Null only on a row written before schema v11, where it reads as "not
/// recorded" — every point this app writes sets it to the person who
/// saved it. It is deliberately not [SyncMeta.lastModifiedBy], which names
/// whoever last *touched* the row: a colleague who corrects the precision
/// figure has not become the person who found the collar.
///
/// **A fact about the record, not a permission.** Any contributor may
/// still edit or delete the point — `truthPointEditVerdict` does not read
/// this column and must not start to. Michael settled that on 2026-08-31:
/// the person who saw the pride and the person driving the truck may not
/// be the same person.
@override final  String? userId;
/// How the coordinate was got: a GPS fix, a hand-placed pin, or a fix
/// somebody later nudged by hand (task 11.93).
///
/// Null only on a row written before schema v11, where it reads as "not
/// recorded". [PositionSource.gpsFixAdjusted] exists because the position
/// became editable in the same task: a point that began as a measurement
/// and was moved by hand is neither of the other two, and the precision
/// radius alone cannot say which it is.
@override final  PositionSource? positionSource;
@override final  SyncMeta sync;

/// Create a copy of ActualTagLocation
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ActualTagLocationCopyWith<_ActualTagLocation> get copyWith => __$ActualTagLocationCopyWithImpl<_ActualTagLocation>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ActualTagLocation&&(identical(other.locationId, locationId) || other.locationId == locationId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.timestampLocal, timestampLocal) || other.timestampLocal == timestampLocal)&&(identical(other.timestampUtc, timestampUtc) || other.timestampUtc == timestampUtc)&&(identical(other.timezoneOffset, timezoneOffset) || other.timezoneOffset == timezoneOffset)&&(identical(other.latitude, latitude) || other.latitude == latitude)&&(identical(other.longitude, longitude) || other.longitude == longitude)&&(identical(other.uncertaintyRadius, uncertaintyRadius) || other.uncertaintyRadius == uncertaintyRadius)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.foundKind, foundKind) || other.foundKind == foundKind)&&(identical(other.tagVersionId, tagVersionId) || other.tagVersionId == tagVersionId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.positionSource, positionSource) || other.positionSource == positionSource)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,locationId,projectId,tagId,timestampLocal,timestampUtc,timezoneOffset,latitude,longitude,uncertaintyRadius,notes,foundKind,tagVersionId,userId,positionSource,sync);

@override
String toString() {
  return 'ActualTagLocation(locationId: $locationId, projectId: $projectId, tagId: $tagId, timestampLocal: $timestampLocal, timestampUtc: $timestampUtc, timezoneOffset: $timezoneOffset, latitude: $latitude, longitude: $longitude, uncertaintyRadius: $uncertaintyRadius, notes: $notes, foundKind: $foundKind, tagVersionId: $tagVersionId, userId: $userId, positionSource: $positionSource, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$ActualTagLocationCopyWith<$Res> implements $ActualTagLocationCopyWith<$Res> {
  factory _$ActualTagLocationCopyWith(_ActualTagLocation value, $Res Function(_ActualTagLocation) _then) = __$ActualTagLocationCopyWithImpl;
@override @useResult
$Res call({
 String locationId, String projectId, String tagId, DateTime timestampLocal, DateTime timestampUtc, String timezoneOffset, double latitude, double longitude, double uncertaintyRadius, String? notes, GroundTruthKind? foundKind, String? tagVersionId, String? userId, PositionSource? positionSource, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$ActualTagLocationCopyWithImpl<$Res>
    implements _$ActualTagLocationCopyWith<$Res> {
  __$ActualTagLocationCopyWithImpl(this._self, this._then);

  final _ActualTagLocation _self;
  final $Res Function(_ActualTagLocation) _then;

/// Create a copy of ActualTagLocation
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? locationId = null,Object? projectId = null,Object? tagId = null,Object? timestampLocal = null,Object? timestampUtc = null,Object? timezoneOffset = null,Object? latitude = null,Object? longitude = null,Object? uncertaintyRadius = null,Object? notes = freezed,Object? foundKind = freezed,Object? tagVersionId = freezed,Object? userId = freezed,Object? positionSource = freezed,Object? sync = null,}) {
  return _then(_ActualTagLocation(
locationId: null == locationId ? _self.locationId : locationId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,timestampLocal: null == timestampLocal ? _self.timestampLocal : timestampLocal // ignore: cast_nullable_to_non_nullable
as DateTime,timestampUtc: null == timestampUtc ? _self.timestampUtc : timestampUtc // ignore: cast_nullable_to_non_nullable
as DateTime,timezoneOffset: null == timezoneOffset ? _self.timezoneOffset : timezoneOffset // ignore: cast_nullable_to_non_nullable
as String,latitude: null == latitude ? _self.latitude : latitude // ignore: cast_nullable_to_non_nullable
as double,longitude: null == longitude ? _self.longitude : longitude // ignore: cast_nullable_to_non_nullable
as double,uncertaintyRadius: null == uncertaintyRadius ? _self.uncertaintyRadius : uncertaintyRadius // ignore: cast_nullable_to_non_nullable
as double,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,foundKind: freezed == foundKind ? _self.foundKind : foundKind // ignore: cast_nullable_to_non_nullable
as GroundTruthKind?,tagVersionId: freezed == tagVersionId ? _self.tagVersionId : tagVersionId // ignore: cast_nullable_to_non_nullable
as String?,userId: freezed == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String?,positionSource: freezed == positionSource ? _self.positionSource : positionSource // ignore: cast_nullable_to_non_nullable
as PositionSource?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of ActualTagLocation
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

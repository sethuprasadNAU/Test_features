// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'project.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$Project {

 String get projectId; String get projectName; String? get description; String? get notes; String get ownerUserId; DateTime get creationDate; double? get bboxMinLat; double? get bboxMinLon; double? get bboxMaxLat; double? get bboxMaxLon; String get datum; CoordinateFormat get coordinateFormat; int get triangulationWindowMinutes;/// Which study this project is a season of (task 11.56, schema v18).
///
/// Shared by every project started from this one, and by this one with
/// the project it was started from — Ponui 2025 and Ponui 2026 carry one
/// value. Null on a row written before v18 or by an older device, and
/// null means *never copied*: read it through [effectiveLineageId], never
/// directly. Sealed like a tag's — recorded, exported, resolved into
/// words about another project by nothing (`provenanceColumns`).
 String? get lineageId;/// When this project was started from another, or null for one created
/// in place — for schema v9's reason: a date invented for it would be a
/// claim about a past nobody observed.
 DateTime? get copiedAt;/// **The field site's time zone** (task 11.331, schema v20) — an IANA
/// name such as `America/Phoenix`. New deployment days, and the
/// deployment form's "today", are read in it; each deployment row copies
/// it into its own `time_zone` when written, so changing it later
/// rewrites nothing (`CLAUDE.md` standing decision 4).
///
/// Defaults at creation to the zone at the center of the project's area
/// (a sea zone at sea, never the nearest land), or the creator's phone's
/// zone when there is no area yet, and the creator confirms it. **Null
/// on a row from a build older than v20**; readers then derive it from
/// the area the same way on every device (`projectTimeZoneProvider`).
 String? get timeZone; SyncMeta get sync;
/// Create a copy of Project
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProjectCopyWith<Project> get copyWith => _$ProjectCopyWithImpl<Project>(this as Project, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Project&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.projectName, projectName) || other.projectName == projectName)&&(identical(other.description, description) || other.description == description)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.ownerUserId, ownerUserId) || other.ownerUserId == ownerUserId)&&(identical(other.creationDate, creationDate) || other.creationDate == creationDate)&&(identical(other.bboxMinLat, bboxMinLat) || other.bboxMinLat == bboxMinLat)&&(identical(other.bboxMinLon, bboxMinLon) || other.bboxMinLon == bboxMinLon)&&(identical(other.bboxMaxLat, bboxMaxLat) || other.bboxMaxLat == bboxMaxLat)&&(identical(other.bboxMaxLon, bboxMaxLon) || other.bboxMaxLon == bboxMaxLon)&&(identical(other.datum, datum) || other.datum == datum)&&(identical(other.coordinateFormat, coordinateFormat) || other.coordinateFormat == coordinateFormat)&&(identical(other.triangulationWindowMinutes, triangulationWindowMinutes) || other.triangulationWindowMinutes == triangulationWindowMinutes)&&(identical(other.lineageId, lineageId) || other.lineageId == lineageId)&&(identical(other.copiedAt, copiedAt) || other.copiedAt == copiedAt)&&(identical(other.timeZone, timeZone) || other.timeZone == timeZone)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,projectId,projectName,description,notes,ownerUserId,creationDate,bboxMinLat,bboxMinLon,bboxMaxLat,bboxMaxLon,datum,coordinateFormat,triangulationWindowMinutes,lineageId,copiedAt,timeZone,sync);

@override
String toString() {
  return 'Project(projectId: $projectId, projectName: $projectName, description: $description, notes: $notes, ownerUserId: $ownerUserId, creationDate: $creationDate, bboxMinLat: $bboxMinLat, bboxMinLon: $bboxMinLon, bboxMaxLat: $bboxMaxLat, bboxMaxLon: $bboxMaxLon, datum: $datum, coordinateFormat: $coordinateFormat, triangulationWindowMinutes: $triangulationWindowMinutes, lineageId: $lineageId, copiedAt: $copiedAt, timeZone: $timeZone, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $ProjectCopyWith<$Res>  {
  factory $ProjectCopyWith(Project value, $Res Function(Project) _then) = _$ProjectCopyWithImpl;
@useResult
$Res call({
 String projectId, String projectName, String? description, String? notes, String ownerUserId, DateTime creationDate, double? bboxMinLat, double? bboxMinLon, double? bboxMaxLat, double? bboxMaxLon, String datum, CoordinateFormat coordinateFormat, int triangulationWindowMinutes, String? lineageId, DateTime? copiedAt, String? timeZone, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$ProjectCopyWithImpl<$Res>
    implements $ProjectCopyWith<$Res> {
  _$ProjectCopyWithImpl(this._self, this._then);

  final Project _self;
  final $Res Function(Project) _then;

/// Create a copy of Project
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? projectId = null,Object? projectName = null,Object? description = freezed,Object? notes = freezed,Object? ownerUserId = null,Object? creationDate = null,Object? bboxMinLat = freezed,Object? bboxMinLon = freezed,Object? bboxMaxLat = freezed,Object? bboxMaxLon = freezed,Object? datum = null,Object? coordinateFormat = null,Object? triangulationWindowMinutes = null,Object? lineageId = freezed,Object? copiedAt = freezed,Object? timeZone = freezed,Object? sync = null,}) {
  return _then(_self.copyWith(
projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,projectName: null == projectName ? _self.projectName : projectName // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,ownerUserId: null == ownerUserId ? _self.ownerUserId : ownerUserId // ignore: cast_nullable_to_non_nullable
as String,creationDate: null == creationDate ? _self.creationDate : creationDate // ignore: cast_nullable_to_non_nullable
as DateTime,bboxMinLat: freezed == bboxMinLat ? _self.bboxMinLat : bboxMinLat // ignore: cast_nullable_to_non_nullable
as double?,bboxMinLon: freezed == bboxMinLon ? _self.bboxMinLon : bboxMinLon // ignore: cast_nullable_to_non_nullable
as double?,bboxMaxLat: freezed == bboxMaxLat ? _self.bboxMaxLat : bboxMaxLat // ignore: cast_nullable_to_non_nullable
as double?,bboxMaxLon: freezed == bboxMaxLon ? _self.bboxMaxLon : bboxMaxLon // ignore: cast_nullable_to_non_nullable
as double?,datum: null == datum ? _self.datum : datum // ignore: cast_nullable_to_non_nullable
as String,coordinateFormat: null == coordinateFormat ? _self.coordinateFormat : coordinateFormat // ignore: cast_nullable_to_non_nullable
as CoordinateFormat,triangulationWindowMinutes: null == triangulationWindowMinutes ? _self.triangulationWindowMinutes : triangulationWindowMinutes // ignore: cast_nullable_to_non_nullable
as int,lineageId: freezed == lineageId ? _self.lineageId : lineageId // ignore: cast_nullable_to_non_nullable
as String?,copiedAt: freezed == copiedAt ? _self.copiedAt : copiedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,timeZone: freezed == timeZone ? _self.timeZone : timeZone // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of Project
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [Project].
extension ProjectPatterns on Project {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Project value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Project() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Project value)  $default,){
final _that = this;
switch (_that) {
case _Project():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Project value)?  $default,){
final _that = this;
switch (_that) {
case _Project() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String projectId,  String projectName,  String? description,  String? notes,  String ownerUserId,  DateTime creationDate,  double? bboxMinLat,  double? bboxMinLon,  double? bboxMaxLat,  double? bboxMaxLon,  String datum,  CoordinateFormat coordinateFormat,  int triangulationWindowMinutes,  String? lineageId,  DateTime? copiedAt,  String? timeZone,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Project() when $default != null:
return $default(_that.projectId,_that.projectName,_that.description,_that.notes,_that.ownerUserId,_that.creationDate,_that.bboxMinLat,_that.bboxMinLon,_that.bboxMaxLat,_that.bboxMaxLon,_that.datum,_that.coordinateFormat,_that.triangulationWindowMinutes,_that.lineageId,_that.copiedAt,_that.timeZone,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String projectId,  String projectName,  String? description,  String? notes,  String ownerUserId,  DateTime creationDate,  double? bboxMinLat,  double? bboxMinLon,  double? bboxMaxLat,  double? bboxMaxLon,  String datum,  CoordinateFormat coordinateFormat,  int triangulationWindowMinutes,  String? lineageId,  DateTime? copiedAt,  String? timeZone,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _Project():
return $default(_that.projectId,_that.projectName,_that.description,_that.notes,_that.ownerUserId,_that.creationDate,_that.bboxMinLat,_that.bboxMinLon,_that.bboxMaxLat,_that.bboxMaxLon,_that.datum,_that.coordinateFormat,_that.triangulationWindowMinutes,_that.lineageId,_that.copiedAt,_that.timeZone,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String projectId,  String projectName,  String? description,  String? notes,  String ownerUserId,  DateTime creationDate,  double? bboxMinLat,  double? bboxMinLon,  double? bboxMaxLat,  double? bboxMaxLon,  String datum,  CoordinateFormat coordinateFormat,  int triangulationWindowMinutes,  String? lineageId,  DateTime? copiedAt,  String? timeZone,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _Project() when $default != null:
return $default(_that.projectId,_that.projectName,_that.description,_that.notes,_that.ownerUserId,_that.creationDate,_that.bboxMinLat,_that.bboxMinLon,_that.bboxMaxLat,_that.bboxMaxLon,_that.datum,_that.coordinateFormat,_that.triangulationWindowMinutes,_that.lineageId,_that.copiedAt,_that.timeZone,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _Project extends Project {
  const _Project({required this.projectId, required this.projectName, this.description, this.notes, required this.ownerUserId, required this.creationDate, this.bboxMinLat, this.bboxMinLon, this.bboxMaxLat, this.bboxMaxLon, this.datum = 'WGS84', this.coordinateFormat = CoordinateFormat.dd, this.triangulationWindowMinutes = 15, this.lineageId, this.copiedAt, this.timeZone, required this.sync}): super._();
  

@override final  String projectId;
@override final  String projectName;
@override final  String? description;
@override final  String? notes;
@override final  String ownerUserId;
@override final  DateTime creationDate;
@override final  double? bboxMinLat;
@override final  double? bboxMinLon;
@override final  double? bboxMaxLat;
@override final  double? bboxMaxLon;
@override@JsonKey() final  String datum;
@override@JsonKey() final  CoordinateFormat coordinateFormat;
@override@JsonKey() final  int triangulationWindowMinutes;
/// Which study this project is a season of (task 11.56, schema v18).
///
/// Shared by every project started from this one, and by this one with
/// the project it was started from — Ponui 2025 and Ponui 2026 carry one
/// value. Null on a row written before v18 or by an older device, and
/// null means *never copied*: read it through [effectiveLineageId], never
/// directly. Sealed like a tag's — recorded, exported, resolved into
/// words about another project by nothing (`provenanceColumns`).
@override final  String? lineageId;
/// When this project was started from another, or null for one created
/// in place — for schema v9's reason: a date invented for it would be a
/// claim about a past nobody observed.
@override final  DateTime? copiedAt;
/// **The field site's time zone** (task 11.331, schema v20) — an IANA
/// name such as `America/Phoenix`. New deployment days, and the
/// deployment form's "today", are read in it; each deployment row copies
/// it into its own `time_zone` when written, so changing it later
/// rewrites nothing (`CLAUDE.md` standing decision 4).
///
/// Defaults at creation to the zone at the center of the project's area
/// (a sea zone at sea, never the nearest land), or the creator's phone's
/// zone when there is no area yet, and the creator confirms it. **Null
/// on a row from a build older than v20**; readers then derive it from
/// the area the same way on every device (`projectTimeZoneProvider`).
@override final  String? timeZone;
@override final  SyncMeta sync;

/// Create a copy of Project
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProjectCopyWith<_Project> get copyWith => __$ProjectCopyWithImpl<_Project>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Project&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.projectName, projectName) || other.projectName == projectName)&&(identical(other.description, description) || other.description == description)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.ownerUserId, ownerUserId) || other.ownerUserId == ownerUserId)&&(identical(other.creationDate, creationDate) || other.creationDate == creationDate)&&(identical(other.bboxMinLat, bboxMinLat) || other.bboxMinLat == bboxMinLat)&&(identical(other.bboxMinLon, bboxMinLon) || other.bboxMinLon == bboxMinLon)&&(identical(other.bboxMaxLat, bboxMaxLat) || other.bboxMaxLat == bboxMaxLat)&&(identical(other.bboxMaxLon, bboxMaxLon) || other.bboxMaxLon == bboxMaxLon)&&(identical(other.datum, datum) || other.datum == datum)&&(identical(other.coordinateFormat, coordinateFormat) || other.coordinateFormat == coordinateFormat)&&(identical(other.triangulationWindowMinutes, triangulationWindowMinutes) || other.triangulationWindowMinutes == triangulationWindowMinutes)&&(identical(other.lineageId, lineageId) || other.lineageId == lineageId)&&(identical(other.copiedAt, copiedAt) || other.copiedAt == copiedAt)&&(identical(other.timeZone, timeZone) || other.timeZone == timeZone)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,projectId,projectName,description,notes,ownerUserId,creationDate,bboxMinLat,bboxMinLon,bboxMaxLat,bboxMaxLon,datum,coordinateFormat,triangulationWindowMinutes,lineageId,copiedAt,timeZone,sync);

@override
String toString() {
  return 'Project(projectId: $projectId, projectName: $projectName, description: $description, notes: $notes, ownerUserId: $ownerUserId, creationDate: $creationDate, bboxMinLat: $bboxMinLat, bboxMinLon: $bboxMinLon, bboxMaxLat: $bboxMaxLat, bboxMaxLon: $bboxMaxLon, datum: $datum, coordinateFormat: $coordinateFormat, triangulationWindowMinutes: $triangulationWindowMinutes, lineageId: $lineageId, copiedAt: $copiedAt, timeZone: $timeZone, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$ProjectCopyWith<$Res> implements $ProjectCopyWith<$Res> {
  factory _$ProjectCopyWith(_Project value, $Res Function(_Project) _then) = __$ProjectCopyWithImpl;
@override @useResult
$Res call({
 String projectId, String projectName, String? description, String? notes, String ownerUserId, DateTime creationDate, double? bboxMinLat, double? bboxMinLon, double? bboxMaxLat, double? bboxMaxLon, String datum, CoordinateFormat coordinateFormat, int triangulationWindowMinutes, String? lineageId, DateTime? copiedAt, String? timeZone, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$ProjectCopyWithImpl<$Res>
    implements _$ProjectCopyWith<$Res> {
  __$ProjectCopyWithImpl(this._self, this._then);

  final _Project _self;
  final $Res Function(_Project) _then;

/// Create a copy of Project
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? projectId = null,Object? projectName = null,Object? description = freezed,Object? notes = freezed,Object? ownerUserId = null,Object? creationDate = null,Object? bboxMinLat = freezed,Object? bboxMinLon = freezed,Object? bboxMaxLat = freezed,Object? bboxMaxLon = freezed,Object? datum = null,Object? coordinateFormat = null,Object? triangulationWindowMinutes = null,Object? lineageId = freezed,Object? copiedAt = freezed,Object? timeZone = freezed,Object? sync = null,}) {
  return _then(_Project(
projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,projectName: null == projectName ? _self.projectName : projectName // ignore: cast_nullable_to_non_nullable
as String,description: freezed == description ? _self.description : description // ignore: cast_nullable_to_non_nullable
as String?,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,ownerUserId: null == ownerUserId ? _self.ownerUserId : ownerUserId // ignore: cast_nullable_to_non_nullable
as String,creationDate: null == creationDate ? _self.creationDate : creationDate // ignore: cast_nullable_to_non_nullable
as DateTime,bboxMinLat: freezed == bboxMinLat ? _self.bboxMinLat : bboxMinLat // ignore: cast_nullable_to_non_nullable
as double?,bboxMinLon: freezed == bboxMinLon ? _self.bboxMinLon : bboxMinLon // ignore: cast_nullable_to_non_nullable
as double?,bboxMaxLat: freezed == bboxMaxLat ? _self.bboxMaxLat : bboxMaxLat // ignore: cast_nullable_to_non_nullable
as double?,bboxMaxLon: freezed == bboxMaxLon ? _self.bboxMaxLon : bboxMaxLon // ignore: cast_nullable_to_non_nullable
as double?,datum: null == datum ? _self.datum : datum // ignore: cast_nullable_to_non_nullable
as String,coordinateFormat: null == coordinateFormat ? _self.coordinateFormat : coordinateFormat // ignore: cast_nullable_to_non_nullable
as CoordinateFormat,triangulationWindowMinutes: null == triangulationWindowMinutes ? _self.triangulationWindowMinutes : triangulationWindowMinutes // ignore: cast_nullable_to_non_nullable
as int,lineageId: freezed == lineageId ? _self.lineageId : lineageId // ignore: cast_nullable_to_non_nullable
as String?,copiedAt: freezed == copiedAt ? _self.copiedAt : copiedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,timeZone: freezed == timeZone ? _self.timeZone : timeZone // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of Project
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

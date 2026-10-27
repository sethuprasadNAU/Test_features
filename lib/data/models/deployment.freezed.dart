// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'deployment.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$Deployment {

 String get deploymentId;/// The project both ends live in. Part of the key.
 String get projectId;/// The collar. A same-project reference into `Tags`.
 String get tagId;/// The animal. A same-project reference into `Individuals`.
 String get individualId;/// When the collar went on, or **null where nobody wrote it down** —
/// Michael, 2026-09-13: *"It is okay to make the tag put on date and tag
/// off dates empty."*
///
/// **A deployment with no attached date covers no interval, so it
/// attributes no bearings and conflicts with nothing.** That is the
/// correct consequence of not knowing when it started, and it is
/// counter-intuitive enough that it is asserted rather than left to be
/// met: see `DeploymentRepository.animalForObservation` and
/// `DeploymentInterlock`.
 DateTime? get attachedDate;/// When the collar came off, or **null for still on**. Null is not
/// "unknown" here: an open-ended deployment covers everything from
/// [attachedDate] onward, which is why two of them on one animal are
/// refused by the interlock.
 DateTime? get removedDate; String? get notes; SyncMeta get sync;/// **The zone this row's days were written in** (task 11.331, schema
/// v20) — the project's zone at the moment the row was written. A bare
/// day in [attachedDate] or [removedDate] is the start of that day in
/// this zone, so the row reads as the same day on every phone and on the
/// server. **Kept when the project's zone changes later**: a row's days
/// do not move.
///
/// Null for a row from a build older than v20; it is then read in this
/// phone's own zone, which is how that build read it.
 String? get timeZone;
/// Create a copy of Deployment
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DeploymentCopyWith<Deployment> get copyWith => _$DeploymentCopyWithImpl<Deployment>(this as Deployment, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Deployment&&(identical(other.deploymentId, deploymentId) || other.deploymentId == deploymentId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.individualId, individualId) || other.individualId == individualId)&&(identical(other.attachedDate, attachedDate) || other.attachedDate == attachedDate)&&(identical(other.removedDate, removedDate) || other.removedDate == removedDate)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.sync, sync) || other.sync == sync)&&(identical(other.timeZone, timeZone) || other.timeZone == timeZone));
}


@override
int get hashCode => Object.hash(runtimeType,deploymentId,projectId,tagId,individualId,attachedDate,removedDate,notes,sync,timeZone);

@override
String toString() {
  return 'Deployment(deploymentId: $deploymentId, projectId: $projectId, tagId: $tagId, individualId: $individualId, attachedDate: $attachedDate, removedDate: $removedDate, notes: $notes, sync: $sync, timeZone: $timeZone)';
}


}

/// @nodoc
abstract mixin class $DeploymentCopyWith<$Res>  {
  factory $DeploymentCopyWith(Deployment value, $Res Function(Deployment) _then) = _$DeploymentCopyWithImpl;
@useResult
$Res call({
 String deploymentId, String projectId, String tagId, String individualId, DateTime? attachedDate, DateTime? removedDate, String? notes, SyncMeta sync, String? timeZone
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$DeploymentCopyWithImpl<$Res>
    implements $DeploymentCopyWith<$Res> {
  _$DeploymentCopyWithImpl(this._self, this._then);

  final Deployment _self;
  final $Res Function(Deployment) _then;

/// Create a copy of Deployment
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? deploymentId = null,Object? projectId = null,Object? tagId = null,Object? individualId = null,Object? attachedDate = freezed,Object? removedDate = freezed,Object? notes = freezed,Object? sync = null,Object? timeZone = freezed,}) {
  return _then(_self.copyWith(
deploymentId: null == deploymentId ? _self.deploymentId : deploymentId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,individualId: null == individualId ? _self.individualId : individualId // ignore: cast_nullable_to_non_nullable
as String,attachedDate: freezed == attachedDate ? _self.attachedDate : attachedDate // ignore: cast_nullable_to_non_nullable
as DateTime?,removedDate: freezed == removedDate ? _self.removedDate : removedDate // ignore: cast_nullable_to_non_nullable
as DateTime?,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,timeZone: freezed == timeZone ? _self.timeZone : timeZone // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}
/// Create a copy of Deployment
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [Deployment].
extension DeploymentPatterns on Deployment {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Deployment value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Deployment() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Deployment value)  $default,){
final _that = this;
switch (_that) {
case _Deployment():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Deployment value)?  $default,){
final _that = this;
switch (_that) {
case _Deployment() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String deploymentId,  String projectId,  String tagId,  String individualId,  DateTime? attachedDate,  DateTime? removedDate,  String? notes,  SyncMeta sync,  String? timeZone)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Deployment() when $default != null:
return $default(_that.deploymentId,_that.projectId,_that.tagId,_that.individualId,_that.attachedDate,_that.removedDate,_that.notes,_that.sync,_that.timeZone);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String deploymentId,  String projectId,  String tagId,  String individualId,  DateTime? attachedDate,  DateTime? removedDate,  String? notes,  SyncMeta sync,  String? timeZone)  $default,) {final _that = this;
switch (_that) {
case _Deployment():
return $default(_that.deploymentId,_that.projectId,_that.tagId,_that.individualId,_that.attachedDate,_that.removedDate,_that.notes,_that.sync,_that.timeZone);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String deploymentId,  String projectId,  String tagId,  String individualId,  DateTime? attachedDate,  DateTime? removedDate,  String? notes,  SyncMeta sync,  String? timeZone)?  $default,) {final _that = this;
switch (_that) {
case _Deployment() when $default != null:
return $default(_that.deploymentId,_that.projectId,_that.tagId,_that.individualId,_that.attachedDate,_that.removedDate,_that.notes,_that.sync,_that.timeZone);case _:
  return null;

}
}

}

/// @nodoc


class _Deployment extends Deployment {
  const _Deployment({required this.deploymentId, required this.projectId, required this.tagId, required this.individualId, this.attachedDate, this.removedDate, this.notes, required this.sync, this.timeZone}): super._();
  

@override final  String deploymentId;
/// The project both ends live in. Part of the key.
@override final  String projectId;
/// The collar. A same-project reference into `Tags`.
@override final  String tagId;
/// The animal. A same-project reference into `Individuals`.
@override final  String individualId;
/// When the collar went on, or **null where nobody wrote it down** —
/// Michael, 2026-09-13: *"It is okay to make the tag put on date and tag
/// off dates empty."*
///
/// **A deployment with no attached date covers no interval, so it
/// attributes no bearings and conflicts with nothing.** That is the
/// correct consequence of not knowing when it started, and it is
/// counter-intuitive enough that it is asserted rather than left to be
/// met: see `DeploymentRepository.animalForObservation` and
/// `DeploymentInterlock`.
@override final  DateTime? attachedDate;
/// When the collar came off, or **null for still on**. Null is not
/// "unknown" here: an open-ended deployment covers everything from
/// [attachedDate] onward, which is why two of them on one animal are
/// refused by the interlock.
@override final  DateTime? removedDate;
@override final  String? notes;
@override final  SyncMeta sync;
/// **The zone this row's days were written in** (task 11.331, schema
/// v20) — the project's zone at the moment the row was written. A bare
/// day in [attachedDate] or [removedDate] is the start of that day in
/// this zone, so the row reads as the same day on every phone and on the
/// server. **Kept when the project's zone changes later**: a row's days
/// do not move.
///
/// Null for a row from a build older than v20; it is then read in this
/// phone's own zone, which is how that build read it.
@override final  String? timeZone;

/// Create a copy of Deployment
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$DeploymentCopyWith<_Deployment> get copyWith => __$DeploymentCopyWithImpl<_Deployment>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Deployment&&(identical(other.deploymentId, deploymentId) || other.deploymentId == deploymentId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.individualId, individualId) || other.individualId == individualId)&&(identical(other.attachedDate, attachedDate) || other.attachedDate == attachedDate)&&(identical(other.removedDate, removedDate) || other.removedDate == removedDate)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.sync, sync) || other.sync == sync)&&(identical(other.timeZone, timeZone) || other.timeZone == timeZone));
}


@override
int get hashCode => Object.hash(runtimeType,deploymentId,projectId,tagId,individualId,attachedDate,removedDate,notes,sync,timeZone);

@override
String toString() {
  return 'Deployment(deploymentId: $deploymentId, projectId: $projectId, tagId: $tagId, individualId: $individualId, attachedDate: $attachedDate, removedDate: $removedDate, notes: $notes, sync: $sync, timeZone: $timeZone)';
}


}

/// @nodoc
abstract mixin class _$DeploymentCopyWith<$Res> implements $DeploymentCopyWith<$Res> {
  factory _$DeploymentCopyWith(_Deployment value, $Res Function(_Deployment) _then) = __$DeploymentCopyWithImpl;
@override @useResult
$Res call({
 String deploymentId, String projectId, String tagId, String individualId, DateTime? attachedDate, DateTime? removedDate, String? notes, SyncMeta sync, String? timeZone
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$DeploymentCopyWithImpl<$Res>
    implements _$DeploymentCopyWith<$Res> {
  __$DeploymentCopyWithImpl(this._self, this._then);

  final _Deployment _self;
  final $Res Function(_Deployment) _then;

/// Create a copy of Deployment
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? deploymentId = null,Object? projectId = null,Object? tagId = null,Object? individualId = null,Object? attachedDate = freezed,Object? removedDate = freezed,Object? notes = freezed,Object? sync = null,Object? timeZone = freezed,}) {
  return _then(_Deployment(
deploymentId: null == deploymentId ? _self.deploymentId : deploymentId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,individualId: null == individualId ? _self.individualId : individualId // ignore: cast_nullable_to_non_nullable
as String,attachedDate: freezed == attachedDate ? _self.attachedDate : attachedDate // ignore: cast_nullable_to_non_nullable
as DateTime?,removedDate: freezed == removedDate ? _self.removedDate : removedDate // ignore: cast_nullable_to_non_nullable
as DateTime?,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,timeZone: freezed == timeZone ? _self.timeZone : timeZone // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

/// Create a copy of Deployment
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

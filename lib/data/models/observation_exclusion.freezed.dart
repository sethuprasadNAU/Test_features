// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'observation_exclusion.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ObservationExclusion {

 String get exclusionId; String get projectId;/// The observation taken out of analysis.
 String get observationId;/// Who marked it — **not** the observation's author, who is untouched and
/// may be someone else entirely.
 String get userId; ObservationExclusionKind get kind;/// The observation that replaces [observationId], when [kind] is
/// [ObservationExclusionKind.superseded]. Null otherwise.
///
/// May name an observation this device does not hold: sync delivers rows
/// in an order this row cannot constrain. That is inert, not corrupt —
/// the marked observation is out of analysis either way, which is the
/// conservative direction (an estimate never counts evidence twice).
 String? get supersededByObservationId;/// Why, in the marker's own words. Optional, but the Team log shows it:
/// a data-quality decision nobody can account for later is a provenance
/// hole of its own.
 String? get reason; SyncMeta get sync;
/// Create a copy of ObservationExclusion
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ObservationExclusionCopyWith<ObservationExclusion> get copyWith => _$ObservationExclusionCopyWithImpl<ObservationExclusion>(this as ObservationExclusion, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ObservationExclusion&&(identical(other.exclusionId, exclusionId) || other.exclusionId == exclusionId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.observationId, observationId) || other.observationId == observationId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.supersededByObservationId, supersededByObservationId) || other.supersededByObservationId == supersededByObservationId)&&(identical(other.reason, reason) || other.reason == reason)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,exclusionId,projectId,observationId,userId,kind,supersededByObservationId,reason,sync);

@override
String toString() {
  return 'ObservationExclusion(exclusionId: $exclusionId, projectId: $projectId, observationId: $observationId, userId: $userId, kind: $kind, supersededByObservationId: $supersededByObservationId, reason: $reason, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $ObservationExclusionCopyWith<$Res>  {
  factory $ObservationExclusionCopyWith(ObservationExclusion value, $Res Function(ObservationExclusion) _then) = _$ObservationExclusionCopyWithImpl;
@useResult
$Res call({
 String exclusionId, String projectId, String observationId, String userId, ObservationExclusionKind kind, String? supersededByObservationId, String? reason, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$ObservationExclusionCopyWithImpl<$Res>
    implements $ObservationExclusionCopyWith<$Res> {
  _$ObservationExclusionCopyWithImpl(this._self, this._then);

  final ObservationExclusion _self;
  final $Res Function(ObservationExclusion) _then;

/// Create a copy of ObservationExclusion
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? exclusionId = null,Object? projectId = null,Object? observationId = null,Object? userId = null,Object? kind = null,Object? supersededByObservationId = freezed,Object? reason = freezed,Object? sync = null,}) {
  return _then(_self.copyWith(
exclusionId: null == exclusionId ? _self.exclusionId : exclusionId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,observationId: null == observationId ? _self.observationId : observationId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as ObservationExclusionKind,supersededByObservationId: freezed == supersededByObservationId ? _self.supersededByObservationId : supersededByObservationId // ignore: cast_nullable_to_non_nullable
as String?,reason: freezed == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of ObservationExclusion
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [ObservationExclusion].
extension ObservationExclusionPatterns on ObservationExclusion {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ObservationExclusion value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ObservationExclusion() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ObservationExclusion value)  $default,){
final _that = this;
switch (_that) {
case _ObservationExclusion():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ObservationExclusion value)?  $default,){
final _that = this;
switch (_that) {
case _ObservationExclusion() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String exclusionId,  String projectId,  String observationId,  String userId,  ObservationExclusionKind kind,  String? supersededByObservationId,  String? reason,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ObservationExclusion() when $default != null:
return $default(_that.exclusionId,_that.projectId,_that.observationId,_that.userId,_that.kind,_that.supersededByObservationId,_that.reason,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String exclusionId,  String projectId,  String observationId,  String userId,  ObservationExclusionKind kind,  String? supersededByObservationId,  String? reason,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _ObservationExclusion():
return $default(_that.exclusionId,_that.projectId,_that.observationId,_that.userId,_that.kind,_that.supersededByObservationId,_that.reason,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String exclusionId,  String projectId,  String observationId,  String userId,  ObservationExclusionKind kind,  String? supersededByObservationId,  String? reason,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _ObservationExclusion() when $default != null:
return $default(_that.exclusionId,_that.projectId,_that.observationId,_that.userId,_that.kind,_that.supersededByObservationId,_that.reason,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _ObservationExclusion extends ObservationExclusion {
  const _ObservationExclusion({required this.exclusionId, required this.projectId, required this.observationId, required this.userId, required this.kind, this.supersededByObservationId, this.reason, required this.sync}): super._();
  

@override final  String exclusionId;
@override final  String projectId;
/// The observation taken out of analysis.
@override final  String observationId;
/// Who marked it — **not** the observation's author, who is untouched and
/// may be someone else entirely.
@override final  String userId;
@override final  ObservationExclusionKind kind;
/// The observation that replaces [observationId], when [kind] is
/// [ObservationExclusionKind.superseded]. Null otherwise.
///
/// May name an observation this device does not hold: sync delivers rows
/// in an order this row cannot constrain. That is inert, not corrupt —
/// the marked observation is out of analysis either way, which is the
/// conservative direction (an estimate never counts evidence twice).
@override final  String? supersededByObservationId;
/// Why, in the marker's own words. Optional, but the Team log shows it:
/// a data-quality decision nobody can account for later is a provenance
/// hole of its own.
@override final  String? reason;
@override final  SyncMeta sync;

/// Create a copy of ObservationExclusion
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ObservationExclusionCopyWith<_ObservationExclusion> get copyWith => __$ObservationExclusionCopyWithImpl<_ObservationExclusion>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ObservationExclusion&&(identical(other.exclusionId, exclusionId) || other.exclusionId == exclusionId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.observationId, observationId) || other.observationId == observationId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.kind, kind) || other.kind == kind)&&(identical(other.supersededByObservationId, supersededByObservationId) || other.supersededByObservationId == supersededByObservationId)&&(identical(other.reason, reason) || other.reason == reason)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,exclusionId,projectId,observationId,userId,kind,supersededByObservationId,reason,sync);

@override
String toString() {
  return 'ObservationExclusion(exclusionId: $exclusionId, projectId: $projectId, observationId: $observationId, userId: $userId, kind: $kind, supersededByObservationId: $supersededByObservationId, reason: $reason, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$ObservationExclusionCopyWith<$Res> implements $ObservationExclusionCopyWith<$Res> {
  factory _$ObservationExclusionCopyWith(_ObservationExclusion value, $Res Function(_ObservationExclusion) _then) = __$ObservationExclusionCopyWithImpl;
@override @useResult
$Res call({
 String exclusionId, String projectId, String observationId, String userId, ObservationExclusionKind kind, String? supersededByObservationId, String? reason, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$ObservationExclusionCopyWithImpl<$Res>
    implements _$ObservationExclusionCopyWith<$Res> {
  __$ObservationExclusionCopyWithImpl(this._self, this._then);

  final _ObservationExclusion _self;
  final $Res Function(_ObservationExclusion) _then;

/// Create a copy of ObservationExclusion
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? exclusionId = null,Object? projectId = null,Object? observationId = null,Object? userId = null,Object? kind = null,Object? supersededByObservationId = freezed,Object? reason = freezed,Object? sync = null,}) {
  return _then(_ObservationExclusion(
exclusionId: null == exclusionId ? _self.exclusionId : exclusionId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,observationId: null == observationId ? _self.observationId : observationId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,kind: null == kind ? _self.kind : kind // ignore: cast_nullable_to_non_nullable
as ObservationExclusionKind,supersededByObservationId: freezed == supersededByObservationId ? _self.supersededByObservationId : supersededByObservationId // ignore: cast_nullable_to_non_nullable
as String?,reason: freezed == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of ObservationExclusion
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

// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'project_membership.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ProjectMembership {

 String get membershipId; String get projectId; String get userId; DateTime get joinDate; DateTime? get endDate; ProjectRole get role; SyncMeta get sync;
/// Create a copy of ProjectMembership
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProjectMembershipCopyWith<ProjectMembership> get copyWith => _$ProjectMembershipCopyWithImpl<ProjectMembership>(this as ProjectMembership, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProjectMembership&&(identical(other.membershipId, membershipId) || other.membershipId == membershipId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.joinDate, joinDate) || other.joinDate == joinDate)&&(identical(other.endDate, endDate) || other.endDate == endDate)&&(identical(other.role, role) || other.role == role)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,membershipId,projectId,userId,joinDate,endDate,role,sync);

@override
String toString() {
  return 'ProjectMembership(membershipId: $membershipId, projectId: $projectId, userId: $userId, joinDate: $joinDate, endDate: $endDate, role: $role, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $ProjectMembershipCopyWith<$Res>  {
  factory $ProjectMembershipCopyWith(ProjectMembership value, $Res Function(ProjectMembership) _then) = _$ProjectMembershipCopyWithImpl;
@useResult
$Res call({
 String membershipId, String projectId, String userId, DateTime joinDate, DateTime? endDate, ProjectRole role, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$ProjectMembershipCopyWithImpl<$Res>
    implements $ProjectMembershipCopyWith<$Res> {
  _$ProjectMembershipCopyWithImpl(this._self, this._then);

  final ProjectMembership _self;
  final $Res Function(ProjectMembership) _then;

/// Create a copy of ProjectMembership
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? membershipId = null,Object? projectId = null,Object? userId = null,Object? joinDate = null,Object? endDate = freezed,Object? role = null,Object? sync = null,}) {
  return _then(_self.copyWith(
membershipId: null == membershipId ? _self.membershipId : membershipId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,joinDate: null == joinDate ? _self.joinDate : joinDate // ignore: cast_nullable_to_non_nullable
as DateTime,endDate: freezed == endDate ? _self.endDate : endDate // ignore: cast_nullable_to_non_nullable
as DateTime?,role: null == role ? _self.role : role // ignore: cast_nullable_to_non_nullable
as ProjectRole,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of ProjectMembership
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [ProjectMembership].
extension ProjectMembershipPatterns on ProjectMembership {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ProjectMembership value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ProjectMembership() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ProjectMembership value)  $default,){
final _that = this;
switch (_that) {
case _ProjectMembership():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ProjectMembership value)?  $default,){
final _that = this;
switch (_that) {
case _ProjectMembership() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String membershipId,  String projectId,  String userId,  DateTime joinDate,  DateTime? endDate,  ProjectRole role,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ProjectMembership() when $default != null:
return $default(_that.membershipId,_that.projectId,_that.userId,_that.joinDate,_that.endDate,_that.role,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String membershipId,  String projectId,  String userId,  DateTime joinDate,  DateTime? endDate,  ProjectRole role,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _ProjectMembership():
return $default(_that.membershipId,_that.projectId,_that.userId,_that.joinDate,_that.endDate,_that.role,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String membershipId,  String projectId,  String userId,  DateTime joinDate,  DateTime? endDate,  ProjectRole role,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _ProjectMembership() when $default != null:
return $default(_that.membershipId,_that.projectId,_that.userId,_that.joinDate,_that.endDate,_that.role,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _ProjectMembership extends ProjectMembership {
  const _ProjectMembership({required this.membershipId, required this.projectId, required this.userId, required this.joinDate, this.endDate, required this.role, required this.sync}): super._();
  

@override final  String membershipId;
@override final  String projectId;
@override final  String userId;
@override final  DateTime joinDate;
@override final  DateTime? endDate;
@override final  ProjectRole role;
@override final  SyncMeta sync;

/// Create a copy of ProjectMembership
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ProjectMembershipCopyWith<_ProjectMembership> get copyWith => __$ProjectMembershipCopyWithImpl<_ProjectMembership>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ProjectMembership&&(identical(other.membershipId, membershipId) || other.membershipId == membershipId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.joinDate, joinDate) || other.joinDate == joinDate)&&(identical(other.endDate, endDate) || other.endDate == endDate)&&(identical(other.role, role) || other.role == role)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,membershipId,projectId,userId,joinDate,endDate,role,sync);

@override
String toString() {
  return 'ProjectMembership(membershipId: $membershipId, projectId: $projectId, userId: $userId, joinDate: $joinDate, endDate: $endDate, role: $role, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$ProjectMembershipCopyWith<$Res> implements $ProjectMembershipCopyWith<$Res> {
  factory _$ProjectMembershipCopyWith(_ProjectMembership value, $Res Function(_ProjectMembership) _then) = __$ProjectMembershipCopyWithImpl;
@override @useResult
$Res call({
 String membershipId, String projectId, String userId, DateTime joinDate, DateTime? endDate, ProjectRole role, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$ProjectMembershipCopyWithImpl<$Res>
    implements _$ProjectMembershipCopyWith<$Res> {
  __$ProjectMembershipCopyWithImpl(this._self, this._then);

  final _ProjectMembership _self;
  final $Res Function(_ProjectMembership) _then;

/// Create a copy of ProjectMembership
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? membershipId = null,Object? projectId = null,Object? userId = null,Object? joinDate = null,Object? endDate = freezed,Object? role = null,Object? sync = null,}) {
  return _then(_ProjectMembership(
membershipId: null == membershipId ? _self.membershipId : membershipId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,joinDate: null == joinDate ? _self.joinDate : joinDate // ignore: cast_nullable_to_non_nullable
as DateTime,endDate: freezed == endDate ? _self.endDate : endDate // ignore: cast_nullable_to_non_nullable
as DateTime?,role: null == role ? _self.role : role // ignore: cast_nullable_to_non_nullable
as ProjectRole,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of ProjectMembership
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

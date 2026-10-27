// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'user_email.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$UserEmail {

 String get userEmailId; String get userId; String get email; DateTime get recordedAt; SyncMeta get sync;
/// Create a copy of UserEmail
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UserEmailCopyWith<UserEmail> get copyWith => _$UserEmailCopyWithImpl<UserEmail>(this as UserEmail, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UserEmail&&(identical(other.userEmailId, userEmailId) || other.userEmailId == userEmailId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.email, email) || other.email == email)&&(identical(other.recordedAt, recordedAt) || other.recordedAt == recordedAt)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,userEmailId,userId,email,recordedAt,sync);

@override
String toString() {
  return 'UserEmail(userEmailId: $userEmailId, userId: $userId, email: $email, recordedAt: $recordedAt, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $UserEmailCopyWith<$Res>  {
  factory $UserEmailCopyWith(UserEmail value, $Res Function(UserEmail) _then) = _$UserEmailCopyWithImpl;
@useResult
$Res call({
 String userEmailId, String userId, String email, DateTime recordedAt, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$UserEmailCopyWithImpl<$Res>
    implements $UserEmailCopyWith<$Res> {
  _$UserEmailCopyWithImpl(this._self, this._then);

  final UserEmail _self;
  final $Res Function(UserEmail) _then;

/// Create a copy of UserEmail
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? userEmailId = null,Object? userId = null,Object? email = null,Object? recordedAt = null,Object? sync = null,}) {
  return _then(_self.copyWith(
userEmailId: null == userEmailId ? _self.userEmailId : userEmailId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,email: null == email ? _self.email : email // ignore: cast_nullable_to_non_nullable
as String,recordedAt: null == recordedAt ? _self.recordedAt : recordedAt // ignore: cast_nullable_to_non_nullable
as DateTime,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of UserEmail
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [UserEmail].
extension UserEmailPatterns on UserEmail {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _UserEmail value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _UserEmail() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _UserEmail value)  $default,){
final _that = this;
switch (_that) {
case _UserEmail():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _UserEmail value)?  $default,){
final _that = this;
switch (_that) {
case _UserEmail() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String userEmailId,  String userId,  String email,  DateTime recordedAt,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _UserEmail() when $default != null:
return $default(_that.userEmailId,_that.userId,_that.email,_that.recordedAt,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String userEmailId,  String userId,  String email,  DateTime recordedAt,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _UserEmail():
return $default(_that.userEmailId,_that.userId,_that.email,_that.recordedAt,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String userEmailId,  String userId,  String email,  DateTime recordedAt,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _UserEmail() when $default != null:
return $default(_that.userEmailId,_that.userId,_that.email,_that.recordedAt,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _UserEmail extends UserEmail {
  const _UserEmail({required this.userEmailId, required this.userId, required this.email, required this.recordedAt, required this.sync}): super._();
  

@override final  String userEmailId;
@override final  String userId;
@override final  String email;
@override final  DateTime recordedAt;
@override final  SyncMeta sync;

/// Create a copy of UserEmail
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$UserEmailCopyWith<_UserEmail> get copyWith => __$UserEmailCopyWithImpl<_UserEmail>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _UserEmail&&(identical(other.userEmailId, userEmailId) || other.userEmailId == userEmailId)&&(identical(other.userId, userId) || other.userId == userId)&&(identical(other.email, email) || other.email == email)&&(identical(other.recordedAt, recordedAt) || other.recordedAt == recordedAt)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,userEmailId,userId,email,recordedAt,sync);

@override
String toString() {
  return 'UserEmail(userEmailId: $userEmailId, userId: $userId, email: $email, recordedAt: $recordedAt, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$UserEmailCopyWith<$Res> implements $UserEmailCopyWith<$Res> {
  factory _$UserEmailCopyWith(_UserEmail value, $Res Function(_UserEmail) _then) = __$UserEmailCopyWithImpl;
@override @useResult
$Res call({
 String userEmailId, String userId, String email, DateTime recordedAt, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$UserEmailCopyWithImpl<$Res>
    implements _$UserEmailCopyWith<$Res> {
  __$UserEmailCopyWithImpl(this._self, this._then);

  final _UserEmail _self;
  final $Res Function(_UserEmail) _then;

/// Create a copy of UserEmail
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? userEmailId = null,Object? userId = null,Object? email = null,Object? recordedAt = null,Object? sync = null,}) {
  return _then(_UserEmail(
userEmailId: null == userEmailId ? _self.userEmailId : userEmailId // ignore: cast_nullable_to_non_nullable
as String,userId: null == userId ? _self.userId : userId // ignore: cast_nullable_to_non_nullable
as String,email: null == email ? _self.email : email // ignore: cast_nullable_to_non_nullable
as String,recordedAt: null == recordedAt ? _self.recordedAt : recordedAt // ignore: cast_nullable_to_non_nullable
as DateTime,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of UserEmail
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

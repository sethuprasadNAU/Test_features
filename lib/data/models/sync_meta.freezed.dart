// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'sync_meta.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SyncMeta {

 DateTime get createdAt; DateTime get updatedAt; DateTime? get deletedAt; int get revision; String? get lastModifiedBy; String? get originDeviceId;
/// Create a copy of SyncMeta
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<SyncMeta> get copyWith => _$SyncMetaCopyWithImpl<SyncMeta>(this as SyncMeta, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncMeta&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.deletedAt, deletedAt) || other.deletedAt == deletedAt)&&(identical(other.revision, revision) || other.revision == revision)&&(identical(other.lastModifiedBy, lastModifiedBy) || other.lastModifiedBy == lastModifiedBy)&&(identical(other.originDeviceId, originDeviceId) || other.originDeviceId == originDeviceId));
}


@override
int get hashCode => Object.hash(runtimeType,createdAt,updatedAt,deletedAt,revision,lastModifiedBy,originDeviceId);

@override
String toString() {
  return 'SyncMeta(createdAt: $createdAt, updatedAt: $updatedAt, deletedAt: $deletedAt, revision: $revision, lastModifiedBy: $lastModifiedBy, originDeviceId: $originDeviceId)';
}


}

/// @nodoc
abstract mixin class $SyncMetaCopyWith<$Res>  {
  factory $SyncMetaCopyWith(SyncMeta value, $Res Function(SyncMeta) _then) = _$SyncMetaCopyWithImpl;
@useResult
$Res call({
 DateTime createdAt, DateTime updatedAt, DateTime? deletedAt, int revision, String? lastModifiedBy, String? originDeviceId
});




}
/// @nodoc
class _$SyncMetaCopyWithImpl<$Res>
    implements $SyncMetaCopyWith<$Res> {
  _$SyncMetaCopyWithImpl(this._self, this._then);

  final SyncMeta _self;
  final $Res Function(SyncMeta) _then;

/// Create a copy of SyncMeta
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? createdAt = null,Object? updatedAt = null,Object? deletedAt = freezed,Object? revision = null,Object? lastModifiedBy = freezed,Object? originDeviceId = freezed,}) {
  return _then(_self.copyWith(
createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,deletedAt: freezed == deletedAt ? _self.deletedAt : deletedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,revision: null == revision ? _self.revision : revision // ignore: cast_nullable_to_non_nullable
as int,lastModifiedBy: freezed == lastModifiedBy ? _self.lastModifiedBy : lastModifiedBy // ignore: cast_nullable_to_non_nullable
as String?,originDeviceId: freezed == originDeviceId ? _self.originDeviceId : originDeviceId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [SyncMeta].
extension SyncMetaPatterns on SyncMeta {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SyncMeta value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SyncMeta() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SyncMeta value)  $default,){
final _that = this;
switch (_that) {
case _SyncMeta():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SyncMeta value)?  $default,){
final _that = this;
switch (_that) {
case _SyncMeta() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( DateTime createdAt,  DateTime updatedAt,  DateTime? deletedAt,  int revision,  String? lastModifiedBy,  String? originDeviceId)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SyncMeta() when $default != null:
return $default(_that.createdAt,_that.updatedAt,_that.deletedAt,_that.revision,_that.lastModifiedBy,_that.originDeviceId);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( DateTime createdAt,  DateTime updatedAt,  DateTime? deletedAt,  int revision,  String? lastModifiedBy,  String? originDeviceId)  $default,) {final _that = this;
switch (_that) {
case _SyncMeta():
return $default(_that.createdAt,_that.updatedAt,_that.deletedAt,_that.revision,_that.lastModifiedBy,_that.originDeviceId);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( DateTime createdAt,  DateTime updatedAt,  DateTime? deletedAt,  int revision,  String? lastModifiedBy,  String? originDeviceId)?  $default,) {final _that = this;
switch (_that) {
case _SyncMeta() when $default != null:
return $default(_that.createdAt,_that.updatedAt,_that.deletedAt,_that.revision,_that.lastModifiedBy,_that.originDeviceId);case _:
  return null;

}
}

}

/// @nodoc


class _SyncMeta extends SyncMeta {
  const _SyncMeta({required this.createdAt, required this.updatedAt, this.deletedAt, this.revision = 0, this.lastModifiedBy, this.originDeviceId}): super._();
  

@override final  DateTime createdAt;
@override final  DateTime updatedAt;
@override final  DateTime? deletedAt;
@override@JsonKey() final  int revision;
@override final  String? lastModifiedBy;
@override final  String? originDeviceId;

/// Create a copy of SyncMeta
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SyncMetaCopyWith<_SyncMeta> get copyWith => __$SyncMetaCopyWithImpl<_SyncMeta>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SyncMeta&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.deletedAt, deletedAt) || other.deletedAt == deletedAt)&&(identical(other.revision, revision) || other.revision == revision)&&(identical(other.lastModifiedBy, lastModifiedBy) || other.lastModifiedBy == lastModifiedBy)&&(identical(other.originDeviceId, originDeviceId) || other.originDeviceId == originDeviceId));
}


@override
int get hashCode => Object.hash(runtimeType,createdAt,updatedAt,deletedAt,revision,lastModifiedBy,originDeviceId);

@override
String toString() {
  return 'SyncMeta(createdAt: $createdAt, updatedAt: $updatedAt, deletedAt: $deletedAt, revision: $revision, lastModifiedBy: $lastModifiedBy, originDeviceId: $originDeviceId)';
}


}

/// @nodoc
abstract mixin class _$SyncMetaCopyWith<$Res> implements $SyncMetaCopyWith<$Res> {
  factory _$SyncMetaCopyWith(_SyncMeta value, $Res Function(_SyncMeta) _then) = __$SyncMetaCopyWithImpl;
@override @useResult
$Res call({
 DateTime createdAt, DateTime updatedAt, DateTime? deletedAt, int revision, String? lastModifiedBy, String? originDeviceId
});




}
/// @nodoc
class __$SyncMetaCopyWithImpl<$Res>
    implements _$SyncMetaCopyWith<$Res> {
  __$SyncMetaCopyWithImpl(this._self, this._then);

  final _SyncMeta _self;
  final $Res Function(_SyncMeta) _then;

/// Create a copy of SyncMeta
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? createdAt = null,Object? updatedAt = null,Object? deletedAt = freezed,Object? revision = null,Object? lastModifiedBy = freezed,Object? originDeviceId = freezed,}) {
  return _then(_SyncMeta(
createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,deletedAt: freezed == deletedAt ? _self.deletedAt : deletedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,revision: null == revision ? _self.revision : revision // ignore: cast_nullable_to_non_nullable
as int,lastModifiedBy: freezed == lastModifiedBy ? _self.lastModifiedBy : lastModifiedBy // ignore: cast_nullable_to_non_nullable
as String?,originDeviceId: freezed == originDeviceId ? _self.originDeviceId : originDeviceId // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on

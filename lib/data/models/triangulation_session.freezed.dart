// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'triangulation_session.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$TriangulationSession {

 String get sessionId; String get projectId; String get tagId; String? get label; DateTime get startedAtLocal; DateTime get startedAtUtc; String get startedAtOffset; String? get notes; SyncMeta get sync;
/// Create a copy of TriangulationSession
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TriangulationSessionCopyWith<TriangulationSession> get copyWith => _$TriangulationSessionCopyWithImpl<TriangulationSession>(this as TriangulationSession, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TriangulationSession&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.label, label) || other.label == label)&&(identical(other.startedAtLocal, startedAtLocal) || other.startedAtLocal == startedAtLocal)&&(identical(other.startedAtUtc, startedAtUtc) || other.startedAtUtc == startedAtUtc)&&(identical(other.startedAtOffset, startedAtOffset) || other.startedAtOffset == startedAtOffset)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,projectId,tagId,label,startedAtLocal,startedAtUtc,startedAtOffset,notes,sync);

@override
String toString() {
  return 'TriangulationSession(sessionId: $sessionId, projectId: $projectId, tagId: $tagId, label: $label, startedAtLocal: $startedAtLocal, startedAtUtc: $startedAtUtc, startedAtOffset: $startedAtOffset, notes: $notes, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $TriangulationSessionCopyWith<$Res>  {
  factory $TriangulationSessionCopyWith(TriangulationSession value, $Res Function(TriangulationSession) _then) = _$TriangulationSessionCopyWithImpl;
@useResult
$Res call({
 String sessionId, String projectId, String tagId, String? label, DateTime startedAtLocal, DateTime startedAtUtc, String startedAtOffset, String? notes, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$TriangulationSessionCopyWithImpl<$Res>
    implements $TriangulationSessionCopyWith<$Res> {
  _$TriangulationSessionCopyWithImpl(this._self, this._then);

  final TriangulationSession _self;
  final $Res Function(TriangulationSession) _then;

/// Create a copy of TriangulationSession
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? sessionId = null,Object? projectId = null,Object? tagId = null,Object? label = freezed,Object? startedAtLocal = null,Object? startedAtUtc = null,Object? startedAtOffset = null,Object? notes = freezed,Object? sync = null,}) {
  return _then(_self.copyWith(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,label: freezed == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String?,startedAtLocal: null == startedAtLocal ? _self.startedAtLocal : startedAtLocal // ignore: cast_nullable_to_non_nullable
as DateTime,startedAtUtc: null == startedAtUtc ? _self.startedAtUtc : startedAtUtc // ignore: cast_nullable_to_non_nullable
as DateTime,startedAtOffset: null == startedAtOffset ? _self.startedAtOffset : startedAtOffset // ignore: cast_nullable_to_non_nullable
as String,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of TriangulationSession
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [TriangulationSession].
extension TriangulationSessionPatterns on TriangulationSession {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TriangulationSession value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TriangulationSession() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TriangulationSession value)  $default,){
final _that = this;
switch (_that) {
case _TriangulationSession():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TriangulationSession value)?  $default,){
final _that = this;
switch (_that) {
case _TriangulationSession() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String sessionId,  String projectId,  String tagId,  String? label,  DateTime startedAtLocal,  DateTime startedAtUtc,  String startedAtOffset,  String? notes,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TriangulationSession() when $default != null:
return $default(_that.sessionId,_that.projectId,_that.tagId,_that.label,_that.startedAtLocal,_that.startedAtUtc,_that.startedAtOffset,_that.notes,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String sessionId,  String projectId,  String tagId,  String? label,  DateTime startedAtLocal,  DateTime startedAtUtc,  String startedAtOffset,  String? notes,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _TriangulationSession():
return $default(_that.sessionId,_that.projectId,_that.tagId,_that.label,_that.startedAtLocal,_that.startedAtUtc,_that.startedAtOffset,_that.notes,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String sessionId,  String projectId,  String tagId,  String? label,  DateTime startedAtLocal,  DateTime startedAtUtc,  String startedAtOffset,  String? notes,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _TriangulationSession() when $default != null:
return $default(_that.sessionId,_that.projectId,_that.tagId,_that.label,_that.startedAtLocal,_that.startedAtUtc,_that.startedAtOffset,_that.notes,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _TriangulationSession extends TriangulationSession {
  const _TriangulationSession({required this.sessionId, required this.projectId, required this.tagId, this.label, required this.startedAtLocal, required this.startedAtUtc, required this.startedAtOffset, this.notes, required this.sync}): super._();
  

@override final  String sessionId;
@override final  String projectId;
@override final  String tagId;
@override final  String? label;
@override final  DateTime startedAtLocal;
@override final  DateTime startedAtUtc;
@override final  String startedAtOffset;
@override final  String? notes;
@override final  SyncMeta sync;

/// Create a copy of TriangulationSession
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TriangulationSessionCopyWith<_TriangulationSession> get copyWith => __$TriangulationSessionCopyWithImpl<_TriangulationSession>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TriangulationSession&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.label, label) || other.label == label)&&(identical(other.startedAtLocal, startedAtLocal) || other.startedAtLocal == startedAtLocal)&&(identical(other.startedAtUtc, startedAtUtc) || other.startedAtUtc == startedAtUtc)&&(identical(other.startedAtOffset, startedAtOffset) || other.startedAtOffset == startedAtOffset)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,projectId,tagId,label,startedAtLocal,startedAtUtc,startedAtOffset,notes,sync);

@override
String toString() {
  return 'TriangulationSession(sessionId: $sessionId, projectId: $projectId, tagId: $tagId, label: $label, startedAtLocal: $startedAtLocal, startedAtUtc: $startedAtUtc, startedAtOffset: $startedAtOffset, notes: $notes, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$TriangulationSessionCopyWith<$Res> implements $TriangulationSessionCopyWith<$Res> {
  factory _$TriangulationSessionCopyWith(_TriangulationSession value, $Res Function(_TriangulationSession) _then) = __$TriangulationSessionCopyWithImpl;
@override @useResult
$Res call({
 String sessionId, String projectId, String tagId, String? label, DateTime startedAtLocal, DateTime startedAtUtc, String startedAtOffset, String? notes, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$TriangulationSessionCopyWithImpl<$Res>
    implements _$TriangulationSessionCopyWith<$Res> {
  __$TriangulationSessionCopyWithImpl(this._self, this._then);

  final _TriangulationSession _self;
  final $Res Function(_TriangulationSession) _then;

/// Create a copy of TriangulationSession
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? projectId = null,Object? tagId = null,Object? label = freezed,Object? startedAtLocal = null,Object? startedAtUtc = null,Object? startedAtOffset = null,Object? notes = freezed,Object? sync = null,}) {
  return _then(_TriangulationSession(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,label: freezed == label ? _self.label : label // ignore: cast_nullable_to_non_nullable
as String?,startedAtLocal: null == startedAtLocal ? _self.startedAtLocal : startedAtLocal // ignore: cast_nullable_to_non_nullable
as DateTime,startedAtUtc: null == startedAtUtc ? _self.startedAtUtc : startedAtUtc // ignore: cast_nullable_to_non_nullable
as DateTime,startedAtOffset: null == startedAtOffset ? _self.startedAtOffset : startedAtOffset // ignore: cast_nullable_to_non_nullable
as String,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of TriangulationSession
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

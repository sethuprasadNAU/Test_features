// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'tag_version.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$TagVersion {

 String get tagVersionId;/// The project the tag this versions lives in (task 11.219). Part of the
/// key: a version belongs to one project's copy of a collar, and two
/// projects holding the same collar keep separate chains, which is what
/// copy-on-add means applied to history.
 String get projectId;/// The tag this is a version of.
 String get tagId;/// When this version took effect (UTC).
///
/// Provenance, not a lookup key. An observation names its version by id and
/// never by "whichever version was current at my timestamp" — the two
/// disagree whenever a bearing is entered after the fact, and the id is the
/// answer that stays true.
 DateTime get effectiveFrom; double get frequencyMhz; double? get pulseRate; String? get pulsePattern; String get tagName;/// The tag's pulse modes as this version read them — task 11.187. Slot 1's
/// rate is [pulseRate]; see `pulse_modes.dart`.
 String? get pulseMode1Name; String? get pulseMode2Name; double? get pulseMode2RateBpm; String? get pulseMode3Name; double? get pulseMode3RateBpm; SyncMeta get sync;
/// Create a copy of TagVersion
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TagVersionCopyWith<TagVersion> get copyWith => _$TagVersionCopyWithImpl<TagVersion>(this as TagVersion, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TagVersion&&(identical(other.tagVersionId, tagVersionId) || other.tagVersionId == tagVersionId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.effectiveFrom, effectiveFrom) || other.effectiveFrom == effectiveFrom)&&(identical(other.frequencyMhz, frequencyMhz) || other.frequencyMhz == frequencyMhz)&&(identical(other.pulseRate, pulseRate) || other.pulseRate == pulseRate)&&(identical(other.pulsePattern, pulsePattern) || other.pulsePattern == pulsePattern)&&(identical(other.tagName, tagName) || other.tagName == tagName)&&(identical(other.pulseMode1Name, pulseMode1Name) || other.pulseMode1Name == pulseMode1Name)&&(identical(other.pulseMode2Name, pulseMode2Name) || other.pulseMode2Name == pulseMode2Name)&&(identical(other.pulseMode2RateBpm, pulseMode2RateBpm) || other.pulseMode2RateBpm == pulseMode2RateBpm)&&(identical(other.pulseMode3Name, pulseMode3Name) || other.pulseMode3Name == pulseMode3Name)&&(identical(other.pulseMode3RateBpm, pulseMode3RateBpm) || other.pulseMode3RateBpm == pulseMode3RateBpm)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,tagVersionId,projectId,tagId,effectiveFrom,frequencyMhz,pulseRate,pulsePattern,tagName,pulseMode1Name,pulseMode2Name,pulseMode2RateBpm,pulseMode3Name,pulseMode3RateBpm,sync);

@override
String toString() {
  return 'TagVersion(tagVersionId: $tagVersionId, projectId: $projectId, tagId: $tagId, effectiveFrom: $effectiveFrom, frequencyMhz: $frequencyMhz, pulseRate: $pulseRate, pulsePattern: $pulsePattern, tagName: $tagName, pulseMode1Name: $pulseMode1Name, pulseMode2Name: $pulseMode2Name, pulseMode2RateBpm: $pulseMode2RateBpm, pulseMode3Name: $pulseMode3Name, pulseMode3RateBpm: $pulseMode3RateBpm, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $TagVersionCopyWith<$Res>  {
  factory $TagVersionCopyWith(TagVersion value, $Res Function(TagVersion) _then) = _$TagVersionCopyWithImpl;
@useResult
$Res call({
 String tagVersionId, String projectId, String tagId, DateTime effectiveFrom, double frequencyMhz, double? pulseRate, String? pulsePattern, String tagName, String? pulseMode1Name, String? pulseMode2Name, double? pulseMode2RateBpm, String? pulseMode3Name, double? pulseMode3RateBpm, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$TagVersionCopyWithImpl<$Res>
    implements $TagVersionCopyWith<$Res> {
  _$TagVersionCopyWithImpl(this._self, this._then);

  final TagVersion _self;
  final $Res Function(TagVersion) _then;

/// Create a copy of TagVersion
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? tagVersionId = null,Object? projectId = null,Object? tagId = null,Object? effectiveFrom = null,Object? frequencyMhz = null,Object? pulseRate = freezed,Object? pulsePattern = freezed,Object? tagName = null,Object? pulseMode1Name = freezed,Object? pulseMode2Name = freezed,Object? pulseMode2RateBpm = freezed,Object? pulseMode3Name = freezed,Object? pulseMode3RateBpm = freezed,Object? sync = null,}) {
  return _then(_self.copyWith(
tagVersionId: null == tagVersionId ? _self.tagVersionId : tagVersionId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,effectiveFrom: null == effectiveFrom ? _self.effectiveFrom : effectiveFrom // ignore: cast_nullable_to_non_nullable
as DateTime,frequencyMhz: null == frequencyMhz ? _self.frequencyMhz : frequencyMhz // ignore: cast_nullable_to_non_nullable
as double,pulseRate: freezed == pulseRate ? _self.pulseRate : pulseRate // ignore: cast_nullable_to_non_nullable
as double?,pulsePattern: freezed == pulsePattern ? _self.pulsePattern : pulsePattern // ignore: cast_nullable_to_non_nullable
as String?,tagName: null == tagName ? _self.tagName : tagName // ignore: cast_nullable_to_non_nullable
as String,pulseMode1Name: freezed == pulseMode1Name ? _self.pulseMode1Name : pulseMode1Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2Name: freezed == pulseMode2Name ? _self.pulseMode2Name : pulseMode2Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2RateBpm: freezed == pulseMode2RateBpm ? _self.pulseMode2RateBpm : pulseMode2RateBpm // ignore: cast_nullable_to_non_nullable
as double?,pulseMode3Name: freezed == pulseMode3Name ? _self.pulseMode3Name : pulseMode3Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode3RateBpm: freezed == pulseMode3RateBpm ? _self.pulseMode3RateBpm : pulseMode3RateBpm // ignore: cast_nullable_to_non_nullable
as double?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of TagVersion
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [TagVersion].
extension TagVersionPatterns on TagVersion {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TagVersion value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TagVersion() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TagVersion value)  $default,){
final _that = this;
switch (_that) {
case _TagVersion():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TagVersion value)?  $default,){
final _that = this;
switch (_that) {
case _TagVersion() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String tagVersionId,  String projectId,  String tagId,  DateTime effectiveFrom,  double frequencyMhz,  double? pulseRate,  String? pulsePattern,  String tagName,  String? pulseMode1Name,  String? pulseMode2Name,  double? pulseMode2RateBpm,  String? pulseMode3Name,  double? pulseMode3RateBpm,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TagVersion() when $default != null:
return $default(_that.tagVersionId,_that.projectId,_that.tagId,_that.effectiveFrom,_that.frequencyMhz,_that.pulseRate,_that.pulsePattern,_that.tagName,_that.pulseMode1Name,_that.pulseMode2Name,_that.pulseMode2RateBpm,_that.pulseMode3Name,_that.pulseMode3RateBpm,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String tagVersionId,  String projectId,  String tagId,  DateTime effectiveFrom,  double frequencyMhz,  double? pulseRate,  String? pulsePattern,  String tagName,  String? pulseMode1Name,  String? pulseMode2Name,  double? pulseMode2RateBpm,  String? pulseMode3Name,  double? pulseMode3RateBpm,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _TagVersion():
return $default(_that.tagVersionId,_that.projectId,_that.tagId,_that.effectiveFrom,_that.frequencyMhz,_that.pulseRate,_that.pulsePattern,_that.tagName,_that.pulseMode1Name,_that.pulseMode2Name,_that.pulseMode2RateBpm,_that.pulseMode3Name,_that.pulseMode3RateBpm,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String tagVersionId,  String projectId,  String tagId,  DateTime effectiveFrom,  double frequencyMhz,  double? pulseRate,  String? pulsePattern,  String tagName,  String? pulseMode1Name,  String? pulseMode2Name,  double? pulseMode2RateBpm,  String? pulseMode3Name,  double? pulseMode3RateBpm,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _TagVersion() when $default != null:
return $default(_that.tagVersionId,_that.projectId,_that.tagId,_that.effectiveFrom,_that.frequencyMhz,_that.pulseRate,_that.pulsePattern,_that.tagName,_that.pulseMode1Name,_that.pulseMode2Name,_that.pulseMode2RateBpm,_that.pulseMode3Name,_that.pulseMode3RateBpm,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _TagVersion extends TagVersion {
  const _TagVersion({required this.tagVersionId, required this.projectId, required this.tagId, required this.effectiveFrom, required this.frequencyMhz, this.pulseRate, this.pulsePattern, required this.tagName, this.pulseMode1Name, this.pulseMode2Name, this.pulseMode2RateBpm, this.pulseMode3Name, this.pulseMode3RateBpm, required this.sync}): super._();
  

@override final  String tagVersionId;
/// The project the tag this versions lives in (task 11.219). Part of the
/// key: a version belongs to one project's copy of a collar, and two
/// projects holding the same collar keep separate chains, which is what
/// copy-on-add means applied to history.
@override final  String projectId;
/// The tag this is a version of.
@override final  String tagId;
/// When this version took effect (UTC).
///
/// Provenance, not a lookup key. An observation names its version by id and
/// never by "whichever version was current at my timestamp" — the two
/// disagree whenever a bearing is entered after the fact, and the id is the
/// answer that stays true.
@override final  DateTime effectiveFrom;
@override final  double frequencyMhz;
@override final  double? pulseRate;
@override final  String? pulsePattern;
@override final  String tagName;
/// The tag's pulse modes as this version read them — task 11.187. Slot 1's
/// rate is [pulseRate]; see `pulse_modes.dart`.
@override final  String? pulseMode1Name;
@override final  String? pulseMode2Name;
@override final  double? pulseMode2RateBpm;
@override final  String? pulseMode3Name;
@override final  double? pulseMode3RateBpm;
@override final  SyncMeta sync;

/// Create a copy of TagVersion
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TagVersionCopyWith<_TagVersion> get copyWith => __$TagVersionCopyWithImpl<_TagVersion>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TagVersion&&(identical(other.tagVersionId, tagVersionId) || other.tagVersionId == tagVersionId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.effectiveFrom, effectiveFrom) || other.effectiveFrom == effectiveFrom)&&(identical(other.frequencyMhz, frequencyMhz) || other.frequencyMhz == frequencyMhz)&&(identical(other.pulseRate, pulseRate) || other.pulseRate == pulseRate)&&(identical(other.pulsePattern, pulsePattern) || other.pulsePattern == pulsePattern)&&(identical(other.tagName, tagName) || other.tagName == tagName)&&(identical(other.pulseMode1Name, pulseMode1Name) || other.pulseMode1Name == pulseMode1Name)&&(identical(other.pulseMode2Name, pulseMode2Name) || other.pulseMode2Name == pulseMode2Name)&&(identical(other.pulseMode2RateBpm, pulseMode2RateBpm) || other.pulseMode2RateBpm == pulseMode2RateBpm)&&(identical(other.pulseMode3Name, pulseMode3Name) || other.pulseMode3Name == pulseMode3Name)&&(identical(other.pulseMode3RateBpm, pulseMode3RateBpm) || other.pulseMode3RateBpm == pulseMode3RateBpm)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,tagVersionId,projectId,tagId,effectiveFrom,frequencyMhz,pulseRate,pulsePattern,tagName,pulseMode1Name,pulseMode2Name,pulseMode2RateBpm,pulseMode3Name,pulseMode3RateBpm,sync);

@override
String toString() {
  return 'TagVersion(tagVersionId: $tagVersionId, projectId: $projectId, tagId: $tagId, effectiveFrom: $effectiveFrom, frequencyMhz: $frequencyMhz, pulseRate: $pulseRate, pulsePattern: $pulsePattern, tagName: $tagName, pulseMode1Name: $pulseMode1Name, pulseMode2Name: $pulseMode2Name, pulseMode2RateBpm: $pulseMode2RateBpm, pulseMode3Name: $pulseMode3Name, pulseMode3RateBpm: $pulseMode3RateBpm, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$TagVersionCopyWith<$Res> implements $TagVersionCopyWith<$Res> {
  factory _$TagVersionCopyWith(_TagVersion value, $Res Function(_TagVersion) _then) = __$TagVersionCopyWithImpl;
@override @useResult
$Res call({
 String tagVersionId, String projectId, String tagId, DateTime effectiveFrom, double frequencyMhz, double? pulseRate, String? pulsePattern, String tagName, String? pulseMode1Name, String? pulseMode2Name, double? pulseMode2RateBpm, String? pulseMode3Name, double? pulseMode3RateBpm, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$TagVersionCopyWithImpl<$Res>
    implements _$TagVersionCopyWith<$Res> {
  __$TagVersionCopyWithImpl(this._self, this._then);

  final _TagVersion _self;
  final $Res Function(_TagVersion) _then;

/// Create a copy of TagVersion
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? tagVersionId = null,Object? projectId = null,Object? tagId = null,Object? effectiveFrom = null,Object? frequencyMhz = null,Object? pulseRate = freezed,Object? pulsePattern = freezed,Object? tagName = null,Object? pulseMode1Name = freezed,Object? pulseMode2Name = freezed,Object? pulseMode2RateBpm = freezed,Object? pulseMode3Name = freezed,Object? pulseMode3RateBpm = freezed,Object? sync = null,}) {
  return _then(_TagVersion(
tagVersionId: null == tagVersionId ? _self.tagVersionId : tagVersionId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,effectiveFrom: null == effectiveFrom ? _self.effectiveFrom : effectiveFrom // ignore: cast_nullable_to_non_nullable
as DateTime,frequencyMhz: null == frequencyMhz ? _self.frequencyMhz : frequencyMhz // ignore: cast_nullable_to_non_nullable
as double,pulseRate: freezed == pulseRate ? _self.pulseRate : pulseRate // ignore: cast_nullable_to_non_nullable
as double?,pulsePattern: freezed == pulsePattern ? _self.pulsePattern : pulsePattern // ignore: cast_nullable_to_non_nullable
as String?,tagName: null == tagName ? _self.tagName : tagName // ignore: cast_nullable_to_non_nullable
as String,pulseMode1Name: freezed == pulseMode1Name ? _self.pulseMode1Name : pulseMode1Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2Name: freezed == pulseMode2Name ? _self.pulseMode2Name : pulseMode2Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2RateBpm: freezed == pulseMode2RateBpm ? _self.pulseMode2RateBpm : pulseMode2RateBpm // ignore: cast_nullable_to_non_nullable
as double?,pulseMode3Name: freezed == pulseMode3Name ? _self.pulseMode3Name : pulseMode3Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode3RateBpm: freezed == pulseMode3RateBpm ? _self.pulseMode3RateBpm : pulseMode3RateBpm // ignore: cast_nullable_to_non_nullable
as double?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of TagVersion
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

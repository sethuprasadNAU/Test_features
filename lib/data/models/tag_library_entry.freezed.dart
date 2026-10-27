// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'tag_library_entry.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$TagLibraryEntry {

 String get tagId;/// Which physical collar this is. Shared, unchanged, with every project
/// copy ever made from this entry.
 String get lineageId; double get frequencyMhz; double? get pulseRate; String? get pulsePattern; String get tagName; TagStatus get status; String? get notes;/// **The library keeps a colour, and it is a seed, not a home** — task
/// 11.241's decision, after 11.240 moved colour to the animal and left
/// this one on purpose.
///
/// A library entry is a transmitter in no project, so by the model it has
/// no animal and no colour of its own. It keeps one for the one moment
/// nothing else can supply it: when the collar is copied into a project,
/// the animal created for it starts in this colour, so a collar a person
/// knows as "the orange one" is orange in the new project too (§2.7's
/// habit, kept as a starting point). **After the copy, nothing reads it.**
/// No project row ever joins to it, and changing it here recolours no
/// project — `tag_repository_test.dart` holds that. It looks exactly like
/// a second source of truth and it is not one, which is why this sentence
/// is on the field rather than in a report: the next person to "fix" it
/// should find the reason first.
 String get colorHex; String? get pulseMode1Name; String? get pulseMode2Name; double? get pulseMode2RateBpm; String? get pulseMode3Name; double? get pulseMode3RateBpm; SyncMeta get sync;
/// Create a copy of TagLibraryEntry
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TagLibraryEntryCopyWith<TagLibraryEntry> get copyWith => _$TagLibraryEntryCopyWithImpl<TagLibraryEntry>(this as TagLibraryEntry, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TagLibraryEntry&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.lineageId, lineageId) || other.lineageId == lineageId)&&(identical(other.frequencyMhz, frequencyMhz) || other.frequencyMhz == frequencyMhz)&&(identical(other.pulseRate, pulseRate) || other.pulseRate == pulseRate)&&(identical(other.pulsePattern, pulsePattern) || other.pulsePattern == pulsePattern)&&(identical(other.tagName, tagName) || other.tagName == tagName)&&(identical(other.status, status) || other.status == status)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.colorHex, colorHex) || other.colorHex == colorHex)&&(identical(other.pulseMode1Name, pulseMode1Name) || other.pulseMode1Name == pulseMode1Name)&&(identical(other.pulseMode2Name, pulseMode2Name) || other.pulseMode2Name == pulseMode2Name)&&(identical(other.pulseMode2RateBpm, pulseMode2RateBpm) || other.pulseMode2RateBpm == pulseMode2RateBpm)&&(identical(other.pulseMode3Name, pulseMode3Name) || other.pulseMode3Name == pulseMode3Name)&&(identical(other.pulseMode3RateBpm, pulseMode3RateBpm) || other.pulseMode3RateBpm == pulseMode3RateBpm)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,tagId,lineageId,frequencyMhz,pulseRate,pulsePattern,tagName,status,notes,colorHex,pulseMode1Name,pulseMode2Name,pulseMode2RateBpm,pulseMode3Name,pulseMode3RateBpm,sync);

@override
String toString() {
  return 'TagLibraryEntry(tagId: $tagId, lineageId: $lineageId, frequencyMhz: $frequencyMhz, pulseRate: $pulseRate, pulsePattern: $pulsePattern, tagName: $tagName, status: $status, notes: $notes, colorHex: $colorHex, pulseMode1Name: $pulseMode1Name, pulseMode2Name: $pulseMode2Name, pulseMode2RateBpm: $pulseMode2RateBpm, pulseMode3Name: $pulseMode3Name, pulseMode3RateBpm: $pulseMode3RateBpm, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $TagLibraryEntryCopyWith<$Res>  {
  factory $TagLibraryEntryCopyWith(TagLibraryEntry value, $Res Function(TagLibraryEntry) _then) = _$TagLibraryEntryCopyWithImpl;
@useResult
$Res call({
 String tagId, String lineageId, double frequencyMhz, double? pulseRate, String? pulsePattern, String tagName, TagStatus status, String? notes, String colorHex, String? pulseMode1Name, String? pulseMode2Name, double? pulseMode2RateBpm, String? pulseMode3Name, double? pulseMode3RateBpm, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$TagLibraryEntryCopyWithImpl<$Res>
    implements $TagLibraryEntryCopyWith<$Res> {
  _$TagLibraryEntryCopyWithImpl(this._self, this._then);

  final TagLibraryEntry _self;
  final $Res Function(TagLibraryEntry) _then;

/// Create a copy of TagLibraryEntry
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? tagId = null,Object? lineageId = null,Object? frequencyMhz = null,Object? pulseRate = freezed,Object? pulsePattern = freezed,Object? tagName = null,Object? status = null,Object? notes = freezed,Object? colorHex = null,Object? pulseMode1Name = freezed,Object? pulseMode2Name = freezed,Object? pulseMode2RateBpm = freezed,Object? pulseMode3Name = freezed,Object? pulseMode3RateBpm = freezed,Object? sync = null,}) {
  return _then(_self.copyWith(
tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,lineageId: null == lineageId ? _self.lineageId : lineageId // ignore: cast_nullable_to_non_nullable
as String,frequencyMhz: null == frequencyMhz ? _self.frequencyMhz : frequencyMhz // ignore: cast_nullable_to_non_nullable
as double,pulseRate: freezed == pulseRate ? _self.pulseRate : pulseRate // ignore: cast_nullable_to_non_nullable
as double?,pulsePattern: freezed == pulsePattern ? _self.pulsePattern : pulsePattern // ignore: cast_nullable_to_non_nullable
as String?,tagName: null == tagName ? _self.tagName : tagName // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as TagStatus,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,colorHex: null == colorHex ? _self.colorHex : colorHex // ignore: cast_nullable_to_non_nullable
as String,pulseMode1Name: freezed == pulseMode1Name ? _self.pulseMode1Name : pulseMode1Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2Name: freezed == pulseMode2Name ? _self.pulseMode2Name : pulseMode2Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2RateBpm: freezed == pulseMode2RateBpm ? _self.pulseMode2RateBpm : pulseMode2RateBpm // ignore: cast_nullable_to_non_nullable
as double?,pulseMode3Name: freezed == pulseMode3Name ? _self.pulseMode3Name : pulseMode3Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode3RateBpm: freezed == pulseMode3RateBpm ? _self.pulseMode3RateBpm : pulseMode3RateBpm // ignore: cast_nullable_to_non_nullable
as double?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of TagLibraryEntry
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [TagLibraryEntry].
extension TagLibraryEntryPatterns on TagLibraryEntry {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _TagLibraryEntry value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _TagLibraryEntry() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _TagLibraryEntry value)  $default,){
final _that = this;
switch (_that) {
case _TagLibraryEntry():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _TagLibraryEntry value)?  $default,){
final _that = this;
switch (_that) {
case _TagLibraryEntry() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String tagId,  String lineageId,  double frequencyMhz,  double? pulseRate,  String? pulsePattern,  String tagName,  TagStatus status,  String? notes,  String colorHex,  String? pulseMode1Name,  String? pulseMode2Name,  double? pulseMode2RateBpm,  String? pulseMode3Name,  double? pulseMode3RateBpm,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _TagLibraryEntry() when $default != null:
return $default(_that.tagId,_that.lineageId,_that.frequencyMhz,_that.pulseRate,_that.pulsePattern,_that.tagName,_that.status,_that.notes,_that.colorHex,_that.pulseMode1Name,_that.pulseMode2Name,_that.pulseMode2RateBpm,_that.pulseMode3Name,_that.pulseMode3RateBpm,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String tagId,  String lineageId,  double frequencyMhz,  double? pulseRate,  String? pulsePattern,  String tagName,  TagStatus status,  String? notes,  String colorHex,  String? pulseMode1Name,  String? pulseMode2Name,  double? pulseMode2RateBpm,  String? pulseMode3Name,  double? pulseMode3RateBpm,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _TagLibraryEntry():
return $default(_that.tagId,_that.lineageId,_that.frequencyMhz,_that.pulseRate,_that.pulsePattern,_that.tagName,_that.status,_that.notes,_that.colorHex,_that.pulseMode1Name,_that.pulseMode2Name,_that.pulseMode2RateBpm,_that.pulseMode3Name,_that.pulseMode3RateBpm,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String tagId,  String lineageId,  double frequencyMhz,  double? pulseRate,  String? pulsePattern,  String tagName,  TagStatus status,  String? notes,  String colorHex,  String? pulseMode1Name,  String? pulseMode2Name,  double? pulseMode2RateBpm,  String? pulseMode3Name,  double? pulseMode3RateBpm,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _TagLibraryEntry() when $default != null:
return $default(_that.tagId,_that.lineageId,_that.frequencyMhz,_that.pulseRate,_that.pulsePattern,_that.tagName,_that.status,_that.notes,_that.colorHex,_that.pulseMode1Name,_that.pulseMode2Name,_that.pulseMode2RateBpm,_that.pulseMode3Name,_that.pulseMode3RateBpm,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _TagLibraryEntry extends TagLibraryEntry {
  const _TagLibraryEntry({required this.tagId, required this.lineageId, required this.frequencyMhz, this.pulseRate, this.pulsePattern, required this.tagName, required this.status, this.notes, required this.colorHex, this.pulseMode1Name, this.pulseMode2Name, this.pulseMode2RateBpm, this.pulseMode3Name, this.pulseMode3RateBpm, required this.sync}): super._();
  

@override final  String tagId;
/// Which physical collar this is. Shared, unchanged, with every project
/// copy ever made from this entry.
@override final  String lineageId;
@override final  double frequencyMhz;
@override final  double? pulseRate;
@override final  String? pulsePattern;
@override final  String tagName;
@override final  TagStatus status;
@override final  String? notes;
/// **The library keeps a colour, and it is a seed, not a home** — task
/// 11.241's decision, after 11.240 moved colour to the animal and left
/// this one on purpose.
///
/// A library entry is a transmitter in no project, so by the model it has
/// no animal and no colour of its own. It keeps one for the one moment
/// nothing else can supply it: when the collar is copied into a project,
/// the animal created for it starts in this colour, so a collar a person
/// knows as "the orange one" is orange in the new project too (§2.7's
/// habit, kept as a starting point). **After the copy, nothing reads it.**
/// No project row ever joins to it, and changing it here recolours no
/// project — `tag_repository_test.dart` holds that. It looks exactly like
/// a second source of truth and it is not one, which is why this sentence
/// is on the field rather than in a report: the next person to "fix" it
/// should find the reason first.
@override final  String colorHex;
@override final  String? pulseMode1Name;
@override final  String? pulseMode2Name;
@override final  double? pulseMode2RateBpm;
@override final  String? pulseMode3Name;
@override final  double? pulseMode3RateBpm;
@override final  SyncMeta sync;

/// Create a copy of TagLibraryEntry
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TagLibraryEntryCopyWith<_TagLibraryEntry> get copyWith => __$TagLibraryEntryCopyWithImpl<_TagLibraryEntry>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _TagLibraryEntry&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.lineageId, lineageId) || other.lineageId == lineageId)&&(identical(other.frequencyMhz, frequencyMhz) || other.frequencyMhz == frequencyMhz)&&(identical(other.pulseRate, pulseRate) || other.pulseRate == pulseRate)&&(identical(other.pulsePattern, pulsePattern) || other.pulsePattern == pulsePattern)&&(identical(other.tagName, tagName) || other.tagName == tagName)&&(identical(other.status, status) || other.status == status)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.colorHex, colorHex) || other.colorHex == colorHex)&&(identical(other.pulseMode1Name, pulseMode1Name) || other.pulseMode1Name == pulseMode1Name)&&(identical(other.pulseMode2Name, pulseMode2Name) || other.pulseMode2Name == pulseMode2Name)&&(identical(other.pulseMode2RateBpm, pulseMode2RateBpm) || other.pulseMode2RateBpm == pulseMode2RateBpm)&&(identical(other.pulseMode3Name, pulseMode3Name) || other.pulseMode3Name == pulseMode3Name)&&(identical(other.pulseMode3RateBpm, pulseMode3RateBpm) || other.pulseMode3RateBpm == pulseMode3RateBpm)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,tagId,lineageId,frequencyMhz,pulseRate,pulsePattern,tagName,status,notes,colorHex,pulseMode1Name,pulseMode2Name,pulseMode2RateBpm,pulseMode3Name,pulseMode3RateBpm,sync);

@override
String toString() {
  return 'TagLibraryEntry(tagId: $tagId, lineageId: $lineageId, frequencyMhz: $frequencyMhz, pulseRate: $pulseRate, pulsePattern: $pulsePattern, tagName: $tagName, status: $status, notes: $notes, colorHex: $colorHex, pulseMode1Name: $pulseMode1Name, pulseMode2Name: $pulseMode2Name, pulseMode2RateBpm: $pulseMode2RateBpm, pulseMode3Name: $pulseMode3Name, pulseMode3RateBpm: $pulseMode3RateBpm, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$TagLibraryEntryCopyWith<$Res> implements $TagLibraryEntryCopyWith<$Res> {
  factory _$TagLibraryEntryCopyWith(_TagLibraryEntry value, $Res Function(_TagLibraryEntry) _then) = __$TagLibraryEntryCopyWithImpl;
@override @useResult
$Res call({
 String tagId, String lineageId, double frequencyMhz, double? pulseRate, String? pulsePattern, String tagName, TagStatus status, String? notes, String colorHex, String? pulseMode1Name, String? pulseMode2Name, double? pulseMode2RateBpm, String? pulseMode3Name, double? pulseMode3RateBpm, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$TagLibraryEntryCopyWithImpl<$Res>
    implements _$TagLibraryEntryCopyWith<$Res> {
  __$TagLibraryEntryCopyWithImpl(this._self, this._then);

  final _TagLibraryEntry _self;
  final $Res Function(_TagLibraryEntry) _then;

/// Create a copy of TagLibraryEntry
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? tagId = null,Object? lineageId = null,Object? frequencyMhz = null,Object? pulseRate = freezed,Object? pulsePattern = freezed,Object? tagName = null,Object? status = null,Object? notes = freezed,Object? colorHex = null,Object? pulseMode1Name = freezed,Object? pulseMode2Name = freezed,Object? pulseMode2RateBpm = freezed,Object? pulseMode3Name = freezed,Object? pulseMode3RateBpm = freezed,Object? sync = null,}) {
  return _then(_TagLibraryEntry(
tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,lineageId: null == lineageId ? _self.lineageId : lineageId // ignore: cast_nullable_to_non_nullable
as String,frequencyMhz: null == frequencyMhz ? _self.frequencyMhz : frequencyMhz // ignore: cast_nullable_to_non_nullable
as double,pulseRate: freezed == pulseRate ? _self.pulseRate : pulseRate // ignore: cast_nullable_to_non_nullable
as double?,pulsePattern: freezed == pulsePattern ? _self.pulsePattern : pulsePattern // ignore: cast_nullable_to_non_nullable
as String?,tagName: null == tagName ? _self.tagName : tagName // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as TagStatus,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,colorHex: null == colorHex ? _self.colorHex : colorHex // ignore: cast_nullable_to_non_nullable
as String,pulseMode1Name: freezed == pulseMode1Name ? _self.pulseMode1Name : pulseMode1Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2Name: freezed == pulseMode2Name ? _self.pulseMode2Name : pulseMode2Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2RateBpm: freezed == pulseMode2RateBpm ? _self.pulseMode2RateBpm : pulseMode2RateBpm // ignore: cast_nullable_to_non_nullable
as double?,pulseMode3Name: freezed == pulseMode3Name ? _self.pulseMode3Name : pulseMode3Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode3RateBpm: freezed == pulseMode3RateBpm ? _self.pulseMode3RateBpm : pulseMode3RateBpm // ignore: cast_nullable_to_non_nullable
as double?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of TagLibraryEntry
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

// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'tag.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$Tag {

 String get tagId;/// The project this copy of the collar belongs to. Part of the key.
 String get projectId;/// **Which physical collar this is, across every project that holds a
/// copy of it — recorded, exported, and read by nothing live.**
///
/// A random identifier minted when a tag is first created and carried
/// unchanged by every copy of it, forever. Two projects' tags are the
/// same transmitter exactly when these are equal.
///
/// It is a value rather than a pointer at the source row for three
/// reasons (design §2.3): it cannot dangle, because it names nothing; it
/// is transitive without a project's row ever referring to another
/// project; and it survives the case a pointer cannot, a tag created
/// inside a project and later copied elsewhere.
///
/// **Nothing in the app resolves it**, and that is enforced rather than
/// promised — `assertSealedColumnsFeedNoReachability` fails if it is
/// ever declared in a set that decides which rows travel. Its use is in
/// an export: a multi-season analysis that has to know two files are
/// about one animal.
 String get lineageId;/// When this copy was made, or null on a tag created in this project.
///
/// Null is the information, not a gap: a tag that was always here was not
/// copied, and a date invented for it would be a claim about a past
/// nobody observed.
 DateTime? get copiedAt; double get frequencyMhz; double? get pulseRate; String? get pulsePattern; String get tagName;/// The **equipment's** state — working, failed, retired, lost. It is not
/// "deployed" (task 11.243): whether a collar is currently on an animal
/// is derived from `Deployments` and is not stored twice.
 TagStatus get status; String? get notes;/// **The colour of the animal currently wearing this collar — derived,
/// never stored on the tag** (task 11.240, re-routed by 11.243).
///
/// On a tag read back from the database this is `Individuals.color_hex`
/// for the animal of the collar's **current deployment** — the one with
/// an attached date and no removed date. A collar on nobody reads
/// [TagColorPalette.noIndividual], a rendering constant, and **that is
/// the normal starting state for a tag rather than an exception**
/// (design §1): equipment is entered before any animal exists.
///
/// It is never written to `Tags.color_hex`, which is retired —
/// [toColumns] sends null — and [fromRow] does not read that column.
/// Recolouring is an edit to the *animal*, so it recolours every collar
/// she has ever worn: Marie is one colour across both her transmitters.
 String get colorHex;/// The animal's name, read through the same current deployment that
/// supplies [colorHex] — never stored on the tag, never sent:
/// [toColumns] omits it. Null for a collar that is on nobody, and on a
/// tag built by hand rather than read from the database.
///
/// **`individualId` was a column here for exactly one schema version**
/// (v16 only) and task 11.243 removed it: the link is dated now, so a tag
/// cannot answer "whose is this" without being told *when*. See
/// `DeploymentRepository.animalForObservation`, which is the answer for a
/// bearing, and `currentAnimalForTag`, which is the answer for a screen.
 String? get individualName;/// **The tag's pulse modes — task 11.187.** Read them through
/// [pulseModes]; these five are the raw columns and slot 1's rate is
/// [pulseRate] above, for the reason `pulse_modes.dart` gives.
 String? get pulseMode1Name; String? get pulseMode2Name; double? get pulseMode2RateBpm; String? get pulseMode3Name; double? get pulseMode3RateBpm; SyncMeta get sync;
/// Create a copy of Tag
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TagCopyWith<Tag> get copyWith => _$TagCopyWithImpl<Tag>(this as Tag, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Tag&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.lineageId, lineageId) || other.lineageId == lineageId)&&(identical(other.copiedAt, copiedAt) || other.copiedAt == copiedAt)&&(identical(other.frequencyMhz, frequencyMhz) || other.frequencyMhz == frequencyMhz)&&(identical(other.pulseRate, pulseRate) || other.pulseRate == pulseRate)&&(identical(other.pulsePattern, pulsePattern) || other.pulsePattern == pulsePattern)&&(identical(other.tagName, tagName) || other.tagName == tagName)&&(identical(other.status, status) || other.status == status)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.colorHex, colorHex) || other.colorHex == colorHex)&&(identical(other.individualName, individualName) || other.individualName == individualName)&&(identical(other.pulseMode1Name, pulseMode1Name) || other.pulseMode1Name == pulseMode1Name)&&(identical(other.pulseMode2Name, pulseMode2Name) || other.pulseMode2Name == pulseMode2Name)&&(identical(other.pulseMode2RateBpm, pulseMode2RateBpm) || other.pulseMode2RateBpm == pulseMode2RateBpm)&&(identical(other.pulseMode3Name, pulseMode3Name) || other.pulseMode3Name == pulseMode3Name)&&(identical(other.pulseMode3RateBpm, pulseMode3RateBpm) || other.pulseMode3RateBpm == pulseMode3RateBpm)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,tagId,projectId,lineageId,copiedAt,frequencyMhz,pulseRate,pulsePattern,tagName,status,notes,colorHex,individualName,pulseMode1Name,pulseMode2Name,pulseMode2RateBpm,pulseMode3Name,pulseMode3RateBpm,sync);

@override
String toString() {
  return 'Tag(tagId: $tagId, projectId: $projectId, lineageId: $lineageId, copiedAt: $copiedAt, frequencyMhz: $frequencyMhz, pulseRate: $pulseRate, pulsePattern: $pulsePattern, tagName: $tagName, status: $status, notes: $notes, colorHex: $colorHex, individualName: $individualName, pulseMode1Name: $pulseMode1Name, pulseMode2Name: $pulseMode2Name, pulseMode2RateBpm: $pulseMode2RateBpm, pulseMode3Name: $pulseMode3Name, pulseMode3RateBpm: $pulseMode3RateBpm, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $TagCopyWith<$Res>  {
  factory $TagCopyWith(Tag value, $Res Function(Tag) _then) = _$TagCopyWithImpl;
@useResult
$Res call({
 String tagId, String projectId, String lineageId, DateTime? copiedAt, double frequencyMhz, double? pulseRate, String? pulsePattern, String tagName, TagStatus status, String? notes, String colorHex, String? individualName, String? pulseMode1Name, String? pulseMode2Name, double? pulseMode2RateBpm, String? pulseMode3Name, double? pulseMode3RateBpm, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$TagCopyWithImpl<$Res>
    implements $TagCopyWith<$Res> {
  _$TagCopyWithImpl(this._self, this._then);

  final Tag _self;
  final $Res Function(Tag) _then;

/// Create a copy of Tag
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? tagId = null,Object? projectId = null,Object? lineageId = null,Object? copiedAt = freezed,Object? frequencyMhz = null,Object? pulseRate = freezed,Object? pulsePattern = freezed,Object? tagName = null,Object? status = null,Object? notes = freezed,Object? colorHex = null,Object? individualName = freezed,Object? pulseMode1Name = freezed,Object? pulseMode2Name = freezed,Object? pulseMode2RateBpm = freezed,Object? pulseMode3Name = freezed,Object? pulseMode3RateBpm = freezed,Object? sync = null,}) {
  return _then(_self.copyWith(
tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,lineageId: null == lineageId ? _self.lineageId : lineageId // ignore: cast_nullable_to_non_nullable
as String,copiedAt: freezed == copiedAt ? _self.copiedAt : copiedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,frequencyMhz: null == frequencyMhz ? _self.frequencyMhz : frequencyMhz // ignore: cast_nullable_to_non_nullable
as double,pulseRate: freezed == pulseRate ? _self.pulseRate : pulseRate // ignore: cast_nullable_to_non_nullable
as double?,pulsePattern: freezed == pulsePattern ? _self.pulsePattern : pulsePattern // ignore: cast_nullable_to_non_nullable
as String?,tagName: null == tagName ? _self.tagName : tagName // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as TagStatus,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,colorHex: null == colorHex ? _self.colorHex : colorHex // ignore: cast_nullable_to_non_nullable
as String,individualName: freezed == individualName ? _self.individualName : individualName // ignore: cast_nullable_to_non_nullable
as String?,pulseMode1Name: freezed == pulseMode1Name ? _self.pulseMode1Name : pulseMode1Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2Name: freezed == pulseMode2Name ? _self.pulseMode2Name : pulseMode2Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2RateBpm: freezed == pulseMode2RateBpm ? _self.pulseMode2RateBpm : pulseMode2RateBpm // ignore: cast_nullable_to_non_nullable
as double?,pulseMode3Name: freezed == pulseMode3Name ? _self.pulseMode3Name : pulseMode3Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode3RateBpm: freezed == pulseMode3RateBpm ? _self.pulseMode3RateBpm : pulseMode3RateBpm // ignore: cast_nullable_to_non_nullable
as double?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of Tag
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [Tag].
extension TagPatterns on Tag {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Tag value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Tag() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Tag value)  $default,){
final _that = this;
switch (_that) {
case _Tag():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Tag value)?  $default,){
final _that = this;
switch (_that) {
case _Tag() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String tagId,  String projectId,  String lineageId,  DateTime? copiedAt,  double frequencyMhz,  double? pulseRate,  String? pulsePattern,  String tagName,  TagStatus status,  String? notes,  String colorHex,  String? individualName,  String? pulseMode1Name,  String? pulseMode2Name,  double? pulseMode2RateBpm,  String? pulseMode3Name,  double? pulseMode3RateBpm,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Tag() when $default != null:
return $default(_that.tagId,_that.projectId,_that.lineageId,_that.copiedAt,_that.frequencyMhz,_that.pulseRate,_that.pulsePattern,_that.tagName,_that.status,_that.notes,_that.colorHex,_that.individualName,_that.pulseMode1Name,_that.pulseMode2Name,_that.pulseMode2RateBpm,_that.pulseMode3Name,_that.pulseMode3RateBpm,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String tagId,  String projectId,  String lineageId,  DateTime? copiedAt,  double frequencyMhz,  double? pulseRate,  String? pulsePattern,  String tagName,  TagStatus status,  String? notes,  String colorHex,  String? individualName,  String? pulseMode1Name,  String? pulseMode2Name,  double? pulseMode2RateBpm,  String? pulseMode3Name,  double? pulseMode3RateBpm,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _Tag():
return $default(_that.tagId,_that.projectId,_that.lineageId,_that.copiedAt,_that.frequencyMhz,_that.pulseRate,_that.pulsePattern,_that.tagName,_that.status,_that.notes,_that.colorHex,_that.individualName,_that.pulseMode1Name,_that.pulseMode2Name,_that.pulseMode2RateBpm,_that.pulseMode3Name,_that.pulseMode3RateBpm,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String tagId,  String projectId,  String lineageId,  DateTime? copiedAt,  double frequencyMhz,  double? pulseRate,  String? pulsePattern,  String tagName,  TagStatus status,  String? notes,  String colorHex,  String? individualName,  String? pulseMode1Name,  String? pulseMode2Name,  double? pulseMode2RateBpm,  String? pulseMode3Name,  double? pulseMode3RateBpm,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _Tag() when $default != null:
return $default(_that.tagId,_that.projectId,_that.lineageId,_that.copiedAt,_that.frequencyMhz,_that.pulseRate,_that.pulsePattern,_that.tagName,_that.status,_that.notes,_that.colorHex,_that.individualName,_that.pulseMode1Name,_that.pulseMode2Name,_that.pulseMode2RateBpm,_that.pulseMode3Name,_that.pulseMode3RateBpm,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _Tag extends Tag {
  const _Tag({required this.tagId, required this.projectId, required this.lineageId, this.copiedAt, required this.frequencyMhz, this.pulseRate, this.pulsePattern, required this.tagName, required this.status, this.notes, required this.colorHex, this.individualName, this.pulseMode1Name, this.pulseMode2Name, this.pulseMode2RateBpm, this.pulseMode3Name, this.pulseMode3RateBpm, required this.sync}): super._();
  

@override final  String tagId;
/// The project this copy of the collar belongs to. Part of the key.
@override final  String projectId;
/// **Which physical collar this is, across every project that holds a
/// copy of it — recorded, exported, and read by nothing live.**
///
/// A random identifier minted when a tag is first created and carried
/// unchanged by every copy of it, forever. Two projects' tags are the
/// same transmitter exactly when these are equal.
///
/// It is a value rather than a pointer at the source row for three
/// reasons (design §2.3): it cannot dangle, because it names nothing; it
/// is transitive without a project's row ever referring to another
/// project; and it survives the case a pointer cannot, a tag created
/// inside a project and later copied elsewhere.
///
/// **Nothing in the app resolves it**, and that is enforced rather than
/// promised — `assertSealedColumnsFeedNoReachability` fails if it is
/// ever declared in a set that decides which rows travel. Its use is in
/// an export: a multi-season analysis that has to know two files are
/// about one animal.
@override final  String lineageId;
/// When this copy was made, or null on a tag created in this project.
///
/// Null is the information, not a gap: a tag that was always here was not
/// copied, and a date invented for it would be a claim about a past
/// nobody observed.
@override final  DateTime? copiedAt;
@override final  double frequencyMhz;
@override final  double? pulseRate;
@override final  String? pulsePattern;
@override final  String tagName;
/// The **equipment's** state — working, failed, retired, lost. It is not
/// "deployed" (task 11.243): whether a collar is currently on an animal
/// is derived from `Deployments` and is not stored twice.
@override final  TagStatus status;
@override final  String? notes;
/// **The colour of the animal currently wearing this collar — derived,
/// never stored on the tag** (task 11.240, re-routed by 11.243).
///
/// On a tag read back from the database this is `Individuals.color_hex`
/// for the animal of the collar's **current deployment** — the one with
/// an attached date and no removed date. A collar on nobody reads
/// [TagColorPalette.noIndividual], a rendering constant, and **that is
/// the normal starting state for a tag rather than an exception**
/// (design §1): equipment is entered before any animal exists.
///
/// It is never written to `Tags.color_hex`, which is retired —
/// [toColumns] sends null — and [fromRow] does not read that column.
/// Recolouring is an edit to the *animal*, so it recolours every collar
/// she has ever worn: Marie is one colour across both her transmitters.
@override final  String colorHex;
/// The animal's name, read through the same current deployment that
/// supplies [colorHex] — never stored on the tag, never sent:
/// [toColumns] omits it. Null for a collar that is on nobody, and on a
/// tag built by hand rather than read from the database.
///
/// **`individualId` was a column here for exactly one schema version**
/// (v16 only) and task 11.243 removed it: the link is dated now, so a tag
/// cannot answer "whose is this" without being told *when*. See
/// `DeploymentRepository.animalForObservation`, which is the answer for a
/// bearing, and `currentAnimalForTag`, which is the answer for a screen.
@override final  String? individualName;
/// **The tag's pulse modes — task 11.187.** Read them through
/// [pulseModes]; these five are the raw columns and slot 1's rate is
/// [pulseRate] above, for the reason `pulse_modes.dart` gives.
@override final  String? pulseMode1Name;
@override final  String? pulseMode2Name;
@override final  double? pulseMode2RateBpm;
@override final  String? pulseMode3Name;
@override final  double? pulseMode3RateBpm;
@override final  SyncMeta sync;

/// Create a copy of Tag
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$TagCopyWith<_Tag> get copyWith => __$TagCopyWithImpl<_Tag>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Tag&&(identical(other.tagId, tagId) || other.tagId == tagId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.lineageId, lineageId) || other.lineageId == lineageId)&&(identical(other.copiedAt, copiedAt) || other.copiedAt == copiedAt)&&(identical(other.frequencyMhz, frequencyMhz) || other.frequencyMhz == frequencyMhz)&&(identical(other.pulseRate, pulseRate) || other.pulseRate == pulseRate)&&(identical(other.pulsePattern, pulsePattern) || other.pulsePattern == pulsePattern)&&(identical(other.tagName, tagName) || other.tagName == tagName)&&(identical(other.status, status) || other.status == status)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.colorHex, colorHex) || other.colorHex == colorHex)&&(identical(other.individualName, individualName) || other.individualName == individualName)&&(identical(other.pulseMode1Name, pulseMode1Name) || other.pulseMode1Name == pulseMode1Name)&&(identical(other.pulseMode2Name, pulseMode2Name) || other.pulseMode2Name == pulseMode2Name)&&(identical(other.pulseMode2RateBpm, pulseMode2RateBpm) || other.pulseMode2RateBpm == pulseMode2RateBpm)&&(identical(other.pulseMode3Name, pulseMode3Name) || other.pulseMode3Name == pulseMode3Name)&&(identical(other.pulseMode3RateBpm, pulseMode3RateBpm) || other.pulseMode3RateBpm == pulseMode3RateBpm)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,tagId,projectId,lineageId,copiedAt,frequencyMhz,pulseRate,pulsePattern,tagName,status,notes,colorHex,individualName,pulseMode1Name,pulseMode2Name,pulseMode2RateBpm,pulseMode3Name,pulseMode3RateBpm,sync);

@override
String toString() {
  return 'Tag(tagId: $tagId, projectId: $projectId, lineageId: $lineageId, copiedAt: $copiedAt, frequencyMhz: $frequencyMhz, pulseRate: $pulseRate, pulsePattern: $pulsePattern, tagName: $tagName, status: $status, notes: $notes, colorHex: $colorHex, individualName: $individualName, pulseMode1Name: $pulseMode1Name, pulseMode2Name: $pulseMode2Name, pulseMode2RateBpm: $pulseMode2RateBpm, pulseMode3Name: $pulseMode3Name, pulseMode3RateBpm: $pulseMode3RateBpm, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$TagCopyWith<$Res> implements $TagCopyWith<$Res> {
  factory _$TagCopyWith(_Tag value, $Res Function(_Tag) _then) = __$TagCopyWithImpl;
@override @useResult
$Res call({
 String tagId, String projectId, String lineageId, DateTime? copiedAt, double frequencyMhz, double? pulseRate, String? pulsePattern, String tagName, TagStatus status, String? notes, String colorHex, String? individualName, String? pulseMode1Name, String? pulseMode2Name, double? pulseMode2RateBpm, String? pulseMode3Name, double? pulseMode3RateBpm, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$TagCopyWithImpl<$Res>
    implements _$TagCopyWith<$Res> {
  __$TagCopyWithImpl(this._self, this._then);

  final _Tag _self;
  final $Res Function(_Tag) _then;

/// Create a copy of Tag
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? tagId = null,Object? projectId = null,Object? lineageId = null,Object? copiedAt = freezed,Object? frequencyMhz = null,Object? pulseRate = freezed,Object? pulsePattern = freezed,Object? tagName = null,Object? status = null,Object? notes = freezed,Object? colorHex = null,Object? individualName = freezed,Object? pulseMode1Name = freezed,Object? pulseMode2Name = freezed,Object? pulseMode2RateBpm = freezed,Object? pulseMode3Name = freezed,Object? pulseMode3RateBpm = freezed,Object? sync = null,}) {
  return _then(_Tag(
tagId: null == tagId ? _self.tagId : tagId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,lineageId: null == lineageId ? _self.lineageId : lineageId // ignore: cast_nullable_to_non_nullable
as String,copiedAt: freezed == copiedAt ? _self.copiedAt : copiedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,frequencyMhz: null == frequencyMhz ? _self.frequencyMhz : frequencyMhz // ignore: cast_nullable_to_non_nullable
as double,pulseRate: freezed == pulseRate ? _self.pulseRate : pulseRate // ignore: cast_nullable_to_non_nullable
as double?,pulsePattern: freezed == pulsePattern ? _self.pulsePattern : pulsePattern // ignore: cast_nullable_to_non_nullable
as String?,tagName: null == tagName ? _self.tagName : tagName // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as TagStatus,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,colorHex: null == colorHex ? _self.colorHex : colorHex // ignore: cast_nullable_to_non_nullable
as String,individualName: freezed == individualName ? _self.individualName : individualName // ignore: cast_nullable_to_non_nullable
as String?,pulseMode1Name: freezed == pulseMode1Name ? _self.pulseMode1Name : pulseMode1Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2Name: freezed == pulseMode2Name ? _self.pulseMode2Name : pulseMode2Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode2RateBpm: freezed == pulseMode2RateBpm ? _self.pulseMode2RateBpm : pulseMode2RateBpm // ignore: cast_nullable_to_non_nullable
as double?,pulseMode3Name: freezed == pulseMode3Name ? _self.pulseMode3Name : pulseMode3Name // ignore: cast_nullable_to_non_nullable
as String?,pulseMode3RateBpm: freezed == pulseMode3RateBpm ? _self.pulseMode3RateBpm : pulseMode3RateBpm // ignore: cast_nullable_to_non_nullable
as double?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of Tag
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

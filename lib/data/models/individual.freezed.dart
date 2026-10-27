// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'individual.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$Individual {

 String get individualId;/// The project this row belongs to. Part of the key.
 String get projectId;/// "Marie". Never inferred from a tag's name except once, by the v16
/// backfill, which says so.
 String get name;/// The one home of colour — `#RRGGBB`.
 String get colorHex; IndividualStatus get status;/// Free text: whatever the project calls the species. Null where nobody
/// wrote it.
 String? get species;/// Null where nobody recorded it, which is a different fact from
/// [IndividualSex.unknown].
 IndividualSex? get sex; String? get notes;/// **Which animal this is, across every project that holds a copy —
/// recorded, exported, and read by nothing live.** The same meaning
/// `Tag.lineageId` has: two projects' individuals are the same bird
/// exactly when these are equal, which is what lets Ponui 2025 and Ponui
/// 2026 be one dataset in an export. Nothing in the app resolves it —
/// `assertSealedColumnsFeedNoReachability` fails if it is ever declared
/// in a set that decides which rows travel.
 String get lineageId;/// When this copy was made, or null on an individual created in this
/// project. Null is the information, not a gap.
 DateTime? get copiedAt; SyncMeta get sync;
/// Create a copy of Individual
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$IndividualCopyWith<Individual> get copyWith => _$IndividualCopyWithImpl<Individual>(this as Individual, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Individual&&(identical(other.individualId, individualId) || other.individualId == individualId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.name, name) || other.name == name)&&(identical(other.colorHex, colorHex) || other.colorHex == colorHex)&&(identical(other.status, status) || other.status == status)&&(identical(other.species, species) || other.species == species)&&(identical(other.sex, sex) || other.sex == sex)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.lineageId, lineageId) || other.lineageId == lineageId)&&(identical(other.copiedAt, copiedAt) || other.copiedAt == copiedAt)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,individualId,projectId,name,colorHex,status,species,sex,notes,lineageId,copiedAt,sync);

@override
String toString() {
  return 'Individual(individualId: $individualId, projectId: $projectId, name: $name, colorHex: $colorHex, status: $status, species: $species, sex: $sex, notes: $notes, lineageId: $lineageId, copiedAt: $copiedAt, sync: $sync)';
}


}

/// @nodoc
abstract mixin class $IndividualCopyWith<$Res>  {
  factory $IndividualCopyWith(Individual value, $Res Function(Individual) _then) = _$IndividualCopyWithImpl;
@useResult
$Res call({
 String individualId, String projectId, String name, String colorHex, IndividualStatus status, String? species, IndividualSex? sex, String? notes, String lineageId, DateTime? copiedAt, SyncMeta sync
});


$SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class _$IndividualCopyWithImpl<$Res>
    implements $IndividualCopyWith<$Res> {
  _$IndividualCopyWithImpl(this._self, this._then);

  final Individual _self;
  final $Res Function(Individual) _then;

/// Create a copy of Individual
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? individualId = null,Object? projectId = null,Object? name = null,Object? colorHex = null,Object? status = null,Object? species = freezed,Object? sex = freezed,Object? notes = freezed,Object? lineageId = null,Object? copiedAt = freezed,Object? sync = null,}) {
  return _then(_self.copyWith(
individualId: null == individualId ? _self.individualId : individualId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,colorHex: null == colorHex ? _self.colorHex : colorHex // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as IndividualStatus,species: freezed == species ? _self.species : species // ignore: cast_nullable_to_non_nullable
as String?,sex: freezed == sex ? _self.sex : sex // ignore: cast_nullable_to_non_nullable
as IndividualSex?,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,lineageId: null == lineageId ? _self.lineageId : lineageId // ignore: cast_nullable_to_non_nullable
as String,copiedAt: freezed == copiedAt ? _self.copiedAt : copiedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}
/// Create a copy of Individual
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$SyncMetaCopyWith<$Res> get sync {
  
  return $SyncMetaCopyWith<$Res>(_self.sync, (value) {
    return _then(_self.copyWith(sync: value));
  });
}
}


/// Adds pattern-matching-related methods to [Individual].
extension IndividualPatterns on Individual {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Individual value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Individual() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Individual value)  $default,){
final _that = this;
switch (_that) {
case _Individual():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Individual value)?  $default,){
final _that = this;
switch (_that) {
case _Individual() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String individualId,  String projectId,  String name,  String colorHex,  IndividualStatus status,  String? species,  IndividualSex? sex,  String? notes,  String lineageId,  DateTime? copiedAt,  SyncMeta sync)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Individual() when $default != null:
return $default(_that.individualId,_that.projectId,_that.name,_that.colorHex,_that.status,_that.species,_that.sex,_that.notes,_that.lineageId,_that.copiedAt,_that.sync);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String individualId,  String projectId,  String name,  String colorHex,  IndividualStatus status,  String? species,  IndividualSex? sex,  String? notes,  String lineageId,  DateTime? copiedAt,  SyncMeta sync)  $default,) {final _that = this;
switch (_that) {
case _Individual():
return $default(_that.individualId,_that.projectId,_that.name,_that.colorHex,_that.status,_that.species,_that.sex,_that.notes,_that.lineageId,_that.copiedAt,_that.sync);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String individualId,  String projectId,  String name,  String colorHex,  IndividualStatus status,  String? species,  IndividualSex? sex,  String? notes,  String lineageId,  DateTime? copiedAt,  SyncMeta sync)?  $default,) {final _that = this;
switch (_that) {
case _Individual() when $default != null:
return $default(_that.individualId,_that.projectId,_that.name,_that.colorHex,_that.status,_that.species,_that.sex,_that.notes,_that.lineageId,_that.copiedAt,_that.sync);case _:
  return null;

}
}

}

/// @nodoc


class _Individual extends Individual {
  const _Individual({required this.individualId, required this.projectId, required this.name, required this.colorHex, required this.status, this.species, this.sex, this.notes, required this.lineageId, this.copiedAt, required this.sync}): super._();
  

@override final  String individualId;
/// The project this row belongs to. Part of the key.
@override final  String projectId;
/// "Marie". Never inferred from a tag's name except once, by the v16
/// backfill, which says so.
@override final  String name;
/// The one home of colour — `#RRGGBB`.
@override final  String colorHex;
@override final  IndividualStatus status;
/// Free text: whatever the project calls the species. Null where nobody
/// wrote it.
@override final  String? species;
/// Null where nobody recorded it, which is a different fact from
/// [IndividualSex.unknown].
@override final  IndividualSex? sex;
@override final  String? notes;
/// **Which animal this is, across every project that holds a copy —
/// recorded, exported, and read by nothing live.** The same meaning
/// `Tag.lineageId` has: two projects' individuals are the same bird
/// exactly when these are equal, which is what lets Ponui 2025 and Ponui
/// 2026 be one dataset in an export. Nothing in the app resolves it —
/// `assertSealedColumnsFeedNoReachability` fails if it is ever declared
/// in a set that decides which rows travel.
@override final  String lineageId;
/// When this copy was made, or null on an individual created in this
/// project. Null is the information, not a gap.
@override final  DateTime? copiedAt;
@override final  SyncMeta sync;

/// Create a copy of Individual
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$IndividualCopyWith<_Individual> get copyWith => __$IndividualCopyWithImpl<_Individual>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _Individual&&(identical(other.individualId, individualId) || other.individualId == individualId)&&(identical(other.projectId, projectId) || other.projectId == projectId)&&(identical(other.name, name) || other.name == name)&&(identical(other.colorHex, colorHex) || other.colorHex == colorHex)&&(identical(other.status, status) || other.status == status)&&(identical(other.species, species) || other.species == species)&&(identical(other.sex, sex) || other.sex == sex)&&(identical(other.notes, notes) || other.notes == notes)&&(identical(other.lineageId, lineageId) || other.lineageId == lineageId)&&(identical(other.copiedAt, copiedAt) || other.copiedAt == copiedAt)&&(identical(other.sync, sync) || other.sync == sync));
}


@override
int get hashCode => Object.hash(runtimeType,individualId,projectId,name,colorHex,status,species,sex,notes,lineageId,copiedAt,sync);

@override
String toString() {
  return 'Individual(individualId: $individualId, projectId: $projectId, name: $name, colorHex: $colorHex, status: $status, species: $species, sex: $sex, notes: $notes, lineageId: $lineageId, copiedAt: $copiedAt, sync: $sync)';
}


}

/// @nodoc
abstract mixin class _$IndividualCopyWith<$Res> implements $IndividualCopyWith<$Res> {
  factory _$IndividualCopyWith(_Individual value, $Res Function(_Individual) _then) = __$IndividualCopyWithImpl;
@override @useResult
$Res call({
 String individualId, String projectId, String name, String colorHex, IndividualStatus status, String? species, IndividualSex? sex, String? notes, String lineageId, DateTime? copiedAt, SyncMeta sync
});


@override $SyncMetaCopyWith<$Res> get sync;

}
/// @nodoc
class __$IndividualCopyWithImpl<$Res>
    implements _$IndividualCopyWith<$Res> {
  __$IndividualCopyWithImpl(this._self, this._then);

  final _Individual _self;
  final $Res Function(_Individual) _then;

/// Create a copy of Individual
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? individualId = null,Object? projectId = null,Object? name = null,Object? colorHex = null,Object? status = null,Object? species = freezed,Object? sex = freezed,Object? notes = freezed,Object? lineageId = null,Object? copiedAt = freezed,Object? sync = null,}) {
  return _then(_Individual(
individualId: null == individualId ? _self.individualId : individualId // ignore: cast_nullable_to_non_nullable
as String,projectId: null == projectId ? _self.projectId : projectId // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,colorHex: null == colorHex ? _self.colorHex : colorHex // ignore: cast_nullable_to_non_nullable
as String,status: null == status ? _self.status : status // ignore: cast_nullable_to_non_nullable
as IndividualStatus,species: freezed == species ? _self.species : species // ignore: cast_nullable_to_non_nullable
as String?,sex: freezed == sex ? _self.sex : sex // ignore: cast_nullable_to_non_nullable
as IndividualSex?,notes: freezed == notes ? _self.notes : notes // ignore: cast_nullable_to_non_nullable
as String?,lineageId: null == lineageId ? _self.lineageId : lineageId // ignore: cast_nullable_to_non_nullable
as String,copiedAt: freezed == copiedAt ? _self.copiedAt : copiedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,sync: null == sync ? _self.sync : sync // ignore: cast_nullable_to_non_nullable
as SyncMeta,
  ));
}

/// Create a copy of Individual
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

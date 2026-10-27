// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'observation_form_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The most recently selected tag id, persisted across records and app
/// restarts. Field users usually track one individual repeatedly, so the tag
/// picker should default to the last one chosen rather than resetting to the
/// middle of the list after every save (see [ObservationForm]'s default logic
/// in the logging screen, which falls back to the middle-of-list behavior
/// when no persisted value exists or it's not in the current project).

@ProviderFor(LastObservationTagId)
final lastObservationTagIdProvider = LastObservationTagIdProvider._();

/// The most recently selected tag id, persisted across records and app
/// restarts. Field users usually track one individual repeatedly, so the tag
/// picker should default to the last one chosen rather than resetting to the
/// middle of the list after every save (see [ObservationForm]'s default logic
/// in the logging screen, which falls back to the middle-of-list behavior
/// when no persisted value exists or it's not in the current project).
final class LastObservationTagIdProvider
    extends $AsyncNotifierProvider<LastObservationTagId, String?> {
  /// The most recently selected tag id, persisted across records and app
  /// restarts. Field users usually track one individual repeatedly, so the tag
  /// picker should default to the last one chosen rather than resetting to the
  /// middle of the list after every save (see [ObservationForm]'s default logic
  /// in the logging screen, which falls back to the middle-of-list behavior
  /// when no persisted value exists or it's not in the current project).
  LastObservationTagIdProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'lastObservationTagIdProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$lastObservationTagIdHash();

  @$internal
  @override
  LastObservationTagId create() => LastObservationTagId();
}

String _$lastObservationTagIdHash() =>
    r'0450eb981950b8188f3d62a33a0d948c010589c8';

/// The most recently selected tag id, persisted across records and app
/// restarts. Field users usually track one individual repeatedly, so the tag
/// picker should default to the last one chosen rather than resetting to the
/// middle of the list after every save (see [ObservationForm]'s default logic
/// in the logging screen, which falls back to the middle-of-list behavior
/// when no persisted value exists or it's not in the current project).

abstract class _$LastObservationTagId extends $AsyncNotifier<String?> {
  FutureOr<String?> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<String?>, String?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<String?>, String?>,
              AsyncValue<String?>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// The chosen [TagWheelSort], persisted the same way [LastObservationTagId]
/// is: a person who sorts the wheel by animal wants it that way tomorrow, and
/// a switch that reset on every launch would be a thing to press before every
/// first bearing of the day.

@ProviderFor(TagWheelSortSetting)
final tagWheelSortSettingProvider = TagWheelSortSettingProvider._();

/// The chosen [TagWheelSort], persisted the same way [LastObservationTagId]
/// is: a person who sorts the wheel by animal wants it that way tomorrow, and
/// a switch that reset on every launch would be a thing to press before every
/// first bearing of the day.
final class TagWheelSortSettingProvider
    extends $AsyncNotifierProvider<TagWheelSortSetting, TagWheelSort> {
  /// The chosen [TagWheelSort], persisted the same way [LastObservationTagId]
  /// is: a person who sorts the wheel by animal wants it that way tomorrow, and
  /// a switch that reset on every launch would be a thing to press before every
  /// first bearing of the day.
  TagWheelSortSettingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'tagWheelSortSettingProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$tagWheelSortSettingHash();

  @$internal
  @override
  TagWheelSortSetting create() => TagWheelSortSetting();
}

String _$tagWheelSortSettingHash() =>
    r'01dd3eabf65a642f8bb90aa71df7ab9eeef30e22';

/// The chosen [TagWheelSort], persisted the same way [LastObservationTagId]
/// is: a person who sorts the wheel by animal wants it that way tomorrow, and
/// a switch that reset on every launch would be a thing to press before every
/// first bearing of the day.

abstract class _$TagWheelSortSetting extends $AsyncNotifier<TagWheelSort> {
  FutureOr<TagWheelSort> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<TagWheelSort>, TagWheelSort>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<TagWheelSort>, TagWheelSort>,
              AsyncValue<TagWheelSort>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(ObservationForm)
final observationFormProvider = ObservationFormProvider._();

final class ObservationFormProvider
    extends $AsyncNotifierProvider<ObservationForm, ObservationDraftState> {
  ObservationFormProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'observationFormProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$observationFormHash();

  @$internal
  @override
  ObservationForm create() => ObservationForm();
}

String _$observationFormHash() => r'185f0f388b26bf229f462dd8ab860a3d3663728b';

abstract class _$ObservationForm extends $AsyncNotifier<ObservationDraftState> {
  FutureOr<ObservationDraftState> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref
            as $Ref<AsyncValue<ObservationDraftState>, ObservationDraftState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<
                AsyncValue<ObservationDraftState>,
                ObservationDraftState
              >,
              AsyncValue<ObservationDraftState>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

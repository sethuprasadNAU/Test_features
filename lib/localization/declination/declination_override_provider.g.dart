// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'declination_override_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// A user-set manual magnetic declination (° east positive) that overrides the
/// WMM-computed value everywhere bearings are turned into true north, or null
/// to use the computed value. Persisted so a deliberate field override sticks
/// across launches; the compass and bearing tools surface a clear badge and
/// require a confirmation whenever it's active, so it can never be forgotten.

@ProviderFor(DeclinationOverride)
final declinationOverrideProvider = DeclinationOverrideProvider._();

/// A user-set manual magnetic declination (° east positive) that overrides the
/// WMM-computed value everywhere bearings are turned into true north, or null
/// to use the computed value. Persisted so a deliberate field override sticks
/// across launches; the compass and bearing tools surface a clear badge and
/// require a confirmation whenever it's active, so it can never be forgotten.
final class DeclinationOverrideProvider
    extends $AsyncNotifierProvider<DeclinationOverride, double?> {
  /// A user-set manual magnetic declination (° east positive) that overrides the
  /// WMM-computed value everywhere bearings are turned into true north, or null
  /// to use the computed value. Persisted so a deliberate field override sticks
  /// across launches; the compass and bearing tools surface a clear badge and
  /// require a confirmation whenever it's active, so it can never be forgotten.
  DeclinationOverrideProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'declinationOverrideProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$declinationOverrideHash();

  @$internal
  @override
  DeclinationOverride create() => DeclinationOverride();
}

String _$declinationOverrideHash() =>
    r'3bb24bf740bbccc0265c7e067c2eb318f87fa8ec';

/// A user-set manual magnetic declination (° east positive) that overrides the
/// WMM-computed value everywhere bearings are turned into true north, or null
/// to use the computed value. Persisted so a deliberate field override sticks
/// across launches; the compass and bearing tools surface a clear badge and
/// require a confirmation whenever it's active, so it can never be forgotten.

abstract class _$DeclinationOverride extends $AsyncNotifier<double?> {
  FutureOr<double?> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<double?>, double?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<double?>, double?>,
              AsyncValue<double?>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

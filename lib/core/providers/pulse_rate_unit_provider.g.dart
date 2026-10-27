// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pulse_rate_unit_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// **One answer for the whole device, remembered across restarts** — Michael's
/// fourth answer of 2026-09-07: *"The seconds ↔ bpm toggle is remembered
/// everywhere… One setting, one answer; no screen disagreeing with another."*
///
/// It is a **device preference, not project or tag data**, and that is
/// deliberate: how a person likes to read a number is not a fact about the
/// collar, so it must not sync, must not version, and must not travel in an
/// export. The stored rate is beats per minute on every device regardless of
/// what any of them is showing.
///
/// `keepAlive: true` for the reason [TagSortOrderSetting] gives: it is read
/// from a bare `ref.read` by callers with no guaranteed listener.

@ProviderFor(PulseRateUnitSetting)
final pulseRateUnitSettingProvider = PulseRateUnitSettingProvider._();

/// **One answer for the whole device, remembered across restarts** — Michael's
/// fourth answer of 2026-09-07: *"The seconds ↔ bpm toggle is remembered
/// everywhere… One setting, one answer; no screen disagreeing with another."*
///
/// It is a **device preference, not project or tag data**, and that is
/// deliberate: how a person likes to read a number is not a fact about the
/// collar, so it must not sync, must not version, and must not travel in an
/// export. The stored rate is beats per minute on every device regardless of
/// what any of them is showing.
///
/// `keepAlive: true` for the reason [TagSortOrderSetting] gives: it is read
/// from a bare `ref.read` by callers with no guaranteed listener.
final class PulseRateUnitSettingProvider
    extends $AsyncNotifierProvider<PulseRateUnitSetting, PulseRateUnit> {
  /// **One answer for the whole device, remembered across restarts** — Michael's
  /// fourth answer of 2026-09-07: *"The seconds ↔ bpm toggle is remembered
  /// everywhere… One setting, one answer; no screen disagreeing with another."*
  ///
  /// It is a **device preference, not project or tag data**, and that is
  /// deliberate: how a person likes to read a number is not a fact about the
  /// collar, so it must not sync, must not version, and must not travel in an
  /// export. The stored rate is beats per minute on every device regardless of
  /// what any of them is showing.
  ///
  /// `keepAlive: true` for the reason [TagSortOrderSetting] gives: it is read
  /// from a bare `ref.read` by callers with no guaranteed listener.
  PulseRateUnitSettingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'pulseRateUnitSettingProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$pulseRateUnitSettingHash();

  @$internal
  @override
  PulseRateUnitSetting create() => PulseRateUnitSetting();
}

String _$pulseRateUnitSettingHash() =>
    r'27d28f90b14e059251b571d09f0cb7b80a35b100';

/// **One answer for the whole device, remembered across restarts** — Michael's
/// fourth answer of 2026-09-07: *"The seconds ↔ bpm toggle is remembered
/// everywhere… One setting, one answer; no screen disagreeing with another."*
///
/// It is a **device preference, not project or tag data**, and that is
/// deliberate: how a person likes to read a number is not a fact about the
/// collar, so it must not sync, must not version, and must not travel in an
/// export. The stored rate is beats per minute on every device regardless of
/// what any of them is showing.
///
/// `keepAlive: true` for the reason [TagSortOrderSetting] gives: it is read
/// from a bare `ref.read` by callers with no guaranteed listener.

abstract class _$PulseRateUnitSetting extends $AsyncNotifier<PulseRateUnit> {
  FutureOr<PulseRateUnit> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<PulseRateUnit>, PulseRateUnit>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<PulseRateUnit>, PulseRateUnit>,
              AsyncValue<PulseRateUnit>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// The chosen unit, or [PulseRateUnit.bpm] while the preference is still being
/// read off disk.
///
/// **A screen must not blank a rate for the moment it takes to load a
/// preference**, and it must not show one in a unit nobody chose either. The
/// stored unit is the safe answer to both: it is what the number actually is,
/// and the switch to seconds happens a frame later if that is what was saved.

@ProviderFor(pulseRateUnit)
final pulseRateUnitProvider = PulseRateUnitProvider._();

/// The chosen unit, or [PulseRateUnit.bpm] while the preference is still being
/// read off disk.
///
/// **A screen must not blank a rate for the moment it takes to load a
/// preference**, and it must not show one in a unit nobody chose either. The
/// stored unit is the safe answer to both: it is what the number actually is,
/// and the switch to seconds happens a frame later if that is what was saved.

final class PulseRateUnitProvider
    extends $FunctionalProvider<PulseRateUnit, PulseRateUnit, PulseRateUnit>
    with $Provider<PulseRateUnit> {
  /// The chosen unit, or [PulseRateUnit.bpm] while the preference is still being
  /// read off disk.
  ///
  /// **A screen must not blank a rate for the moment it takes to load a
  /// preference**, and it must not show one in a unit nobody chose either. The
  /// stored unit is the safe answer to both: it is what the number actually is,
  /// and the switch to seconds happens a frame later if that is what was saved.
  PulseRateUnitProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'pulseRateUnitProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$pulseRateUnitHash();

  @$internal
  @override
  $ProviderElement<PulseRateUnit> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  PulseRateUnit create(Ref ref) {
    return pulseRateUnit(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(PulseRateUnit value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<PulseRateUnit>(value),
    );
  }
}

String _$pulseRateUnitHash() => r'ea560e3e24c2072e6534aef0b48c6d02869084f8';

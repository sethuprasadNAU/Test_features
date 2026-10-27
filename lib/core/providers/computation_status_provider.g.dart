// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'computation_status_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(ComputationStatusNotifier)
final computationStatusProvider = ComputationStatusNotifierProvider._();

final class ComputationStatusNotifierProvider
    extends $NotifierProvider<ComputationStatusNotifier, ComputationStatus> {
  ComputationStatusNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'computationStatusProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$computationStatusNotifierHash();

  @$internal
  @override
  ComputationStatusNotifier create() => ComputationStatusNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ComputationStatus value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ComputationStatus>(value),
    );
  }
}

String _$computationStatusNotifierHash() =>
    r'30f62bda3936365411106b764e5198650f63cfd8';

abstract class _$ComputationStatusNotifier
    extends $Notifier<ComputationStatus> {
  ComputationStatus build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<ComputationStatus, ComputationStatus>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<ComputationStatus, ComputationStatus>,
              ComputationStatus,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

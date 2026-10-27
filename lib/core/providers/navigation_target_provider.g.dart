// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'navigation_target_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Persisted so a field user mid-hike doesn't lose their destination if the
/// app is backgrounded/killed — same `SharedPreferencesAsync` JSON-blob
/// pattern as `ObservationForm`/`CloudBackupSettingsNotifier`. Exactly one
/// target is active at a time; picking a new one silently replaces it
/// (confirmed with the user — matches how turn-by-turn nav apps behave).

@ProviderFor(NavigationTargetNotifier)
final navigationTargetProvider = NavigationTargetNotifierProvider._();

/// Persisted so a field user mid-hike doesn't lose their destination if the
/// app is backgrounded/killed — same `SharedPreferencesAsync` JSON-blob
/// pattern as `ObservationForm`/`CloudBackupSettingsNotifier`. Exactly one
/// target is active at a time; picking a new one silently replaces it
/// (confirmed with the user — matches how turn-by-turn nav apps behave).
final class NavigationTargetNotifierProvider
    extends
        $AsyncNotifierProvider<NavigationTargetNotifier, NavigationTarget?> {
  /// Persisted so a field user mid-hike doesn't lose their destination if the
  /// app is backgrounded/killed — same `SharedPreferencesAsync` JSON-blob
  /// pattern as `ObservationForm`/`CloudBackupSettingsNotifier`. Exactly one
  /// target is active at a time; picking a new one silently replaces it
  /// (confirmed with the user — matches how turn-by-turn nav apps behave).
  NavigationTargetNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'navigationTargetProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$navigationTargetNotifierHash();

  @$internal
  @override
  NavigationTargetNotifier create() => NavigationTargetNotifier();
}

String _$navigationTargetNotifierHash() =>
    r'016e1227990de827ad55ff84faf8183296255904';

/// Persisted so a field user mid-hike doesn't lose their destination if the
/// app is backgrounded/killed — same `SharedPreferencesAsync` JSON-blob
/// pattern as `ObservationForm`/`CloudBackupSettingsNotifier`. Exactly one
/// target is active at a time; picking a new one silently replaces it
/// (confirmed with the user — matches how turn-by-turn nav apps behave).

abstract class _$NavigationTargetNotifier
    extends $AsyncNotifier<NavigationTarget?> {
  FutureOr<NavigationTarget?> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref as $Ref<AsyncValue<NavigationTarget?>, NavigationTarget?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<NavigationTarget?>, NavigationTarget?>,
              AsyncValue<NavigationTarget?>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_router.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The key [TriTrackApp] hands to `MaterialApp.router(scaffoldMessengerKey:)`,
/// so [appRouterProvider] can reach the same [ScaffoldMessenger] to dismiss a
/// showing undo bar on navigation (task 11.42) without needing a
/// [BuildContext] of its own — a provider builder has none.
///
/// **`keepAlive`, and it has to be**: the key must be the *same instance* for
/// the whole run, or `MaterialApp.router` would attach a fresh
/// `ScaffoldMessengerState` to a key nothing else has, and the listener below
/// would dismiss nothing.

@ProviderFor(scaffoldMessengerKey)
final scaffoldMessengerKeyProvider = ScaffoldMessengerKeyProvider._();

/// The key [TriTrackApp] hands to `MaterialApp.router(scaffoldMessengerKey:)`,
/// so [appRouterProvider] can reach the same [ScaffoldMessenger] to dismiss a
/// showing undo bar on navigation (task 11.42) without needing a
/// [BuildContext] of its own — a provider builder has none.
///
/// **`keepAlive`, and it has to be**: the key must be the *same instance* for
/// the whole run, or `MaterialApp.router` would attach a fresh
/// `ScaffoldMessengerState` to a key nothing else has, and the listener below
/// would dismiss nothing.

final class ScaffoldMessengerKeyProvider
    extends
        $FunctionalProvider<
          GlobalKey<ScaffoldMessengerState>,
          GlobalKey<ScaffoldMessengerState>,
          GlobalKey<ScaffoldMessengerState>
        >
    with $Provider<GlobalKey<ScaffoldMessengerState>> {
  /// The key [TriTrackApp] hands to `MaterialApp.router(scaffoldMessengerKey:)`,
  /// so [appRouterProvider] can reach the same [ScaffoldMessenger] to dismiss a
  /// showing undo bar on navigation (task 11.42) without needing a
  /// [BuildContext] of its own — a provider builder has none.
  ///
  /// **`keepAlive`, and it has to be**: the key must be the *same instance* for
  /// the whole run, or `MaterialApp.router` would attach a fresh
  /// `ScaffoldMessengerState` to a key nothing else has, and the listener below
  /// would dismiss nothing.
  ScaffoldMessengerKeyProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'scaffoldMessengerKeyProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$scaffoldMessengerKeyHash();

  @$internal
  @override
  $ProviderElement<GlobalKey<ScaffoldMessengerState>> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  GlobalKey<ScaffoldMessengerState> create(Ref ref) {
    return scaffoldMessengerKey(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(GlobalKey<ScaffoldMessengerState> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<GlobalKey<ScaffoldMessengerState>>(
        value,
      ),
    );
  }
}

String _$scaffoldMessengerKeyHash() =>
    r'6fdcaf2dd3359a74fa6f6d7fbd0c67c54a8e600d';

/// Bottom tab bar per the hi-fi handoff: Map / Record / Compass / Position /
/// More, each an 8px dot + label. "Record" (originally labeled "Log" in the
/// handoff — renamed 2026-07-17, since it's the bearing/GPS recording form,
/// not a list) is the highest-frequency screen. The sortable list of
/// recorded observations lives under More as "Log" instead. Screens outside
/// this five (Login, Log, Tag DB Management, Sharing, Backup, Pre-Trip
/// Checklist) live under More. Login remains un-designed/unbuilt (Phase One
/// has no login flow — see [[tritrack-phase4]]'s currentUser auto-creation).

@ProviderFor(appRouter)
final appRouterProvider = AppRouterProvider._();

/// Bottom tab bar per the hi-fi handoff: Map / Record / Compass / Position /
/// More, each an 8px dot + label. "Record" (originally labeled "Log" in the
/// handoff — renamed 2026-07-17, since it's the bearing/GPS recording form,
/// not a list) is the highest-frequency screen. The sortable list of
/// recorded observations lives under More as "Log" instead. Screens outside
/// this five (Login, Log, Tag DB Management, Sharing, Backup, Pre-Trip
/// Checklist) live under More. Login remains un-designed/unbuilt (Phase One
/// has no login flow — see [[tritrack-phase4]]'s currentUser auto-creation).

final class AppRouterProvider
    extends $FunctionalProvider<GoRouter, GoRouter, GoRouter>
    with $Provider<GoRouter> {
  /// Bottom tab bar per the hi-fi handoff: Map / Record / Compass / Position /
  /// More, each an 8px dot + label. "Record" (originally labeled "Log" in the
  /// handoff — renamed 2026-07-17, since it's the bearing/GPS recording form,
  /// not a list) is the highest-frequency screen. The sortable list of
  /// recorded observations lives under More as "Log" instead. Screens outside
  /// this five (Login, Log, Tag DB Management, Sharing, Backup, Pre-Trip
  /// Checklist) live under More. Login remains un-designed/unbuilt (Phase One
  /// has no login flow — see [[tritrack-phase4]]'s currentUser auto-creation).
  AppRouterProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'appRouterProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$appRouterHash();

  @$internal
  @override
  $ProviderElement<GoRouter> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  GoRouter create(Ref ref) {
    return appRouter(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(GoRouter value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<GoRouter>(value),
    );
  }
}

String _$appRouterHash() => r'83f9faa5223048deb99693e86e0571034ebf52c6';

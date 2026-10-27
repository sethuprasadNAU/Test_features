// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'active_selection_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Persisted IDs only, for now. Phase 1 adds `currentProjectProvider` /
/// `currentUserProvider` that resolve these IDs to full `Project`/`User`
/// rows via the repositories built in that phase — screens should migrate
/// to those once available rather than re-deriving objects from the ID here.
///
/// **Both notifiers below are `keepAlive: true`, not the `@riverpod` default.**
/// This is app-global selection state — task 10.2 set the same precedent for
/// `ServerConfigNotifier` — and callers legitimately mutate them via a bare
/// `ref.read(...).notifier).set(...)` with no active watcher at the call site
/// (`CurrentSession.completeSignIn`, `app_context_provider.dart`'s
/// auto-create path, several `More` screens). An `autoDispose` notifier with
/// no listener can be torn down by Riverpod the instant its refcount hits
/// zero — which a bare `read` can trigger immediately — and if that lands
/// while `set()` is suspended on its `await _prefs.setString(...)`, the
/// `state = AsyncData(...)` assignment after it throws "Cannot use the Ref
/// of ... after it has been disposed." **This happened on a real device**
/// (task 10.4's phone-on-LAN check), crashing inside `completeSignIn`. It did
/// not reproduce in a plain `ProviderContainer` unit test even with a real
/// `Future.delayed` standing in for the network round trip — Riverpod's
/// disposal scheduling goes through a `Vsync` that a widget-bound
/// `ProviderScope` supplies (frame callbacks) and a bare container falls back
/// to a zero-duration `Timer`, so the two don't race identically. `keepAlive`
/// removes the possibility outright rather than depending on reproducing or
/// reasoning about that timing, in either environment.

@ProviderFor(ActiveProjectId)
final activeProjectIdProvider = ActiveProjectIdProvider._();

/// Persisted IDs only, for now. Phase 1 adds `currentProjectProvider` /
/// `currentUserProvider` that resolve these IDs to full `Project`/`User`
/// rows via the repositories built in that phase — screens should migrate
/// to those once available rather than re-deriving objects from the ID here.
///
/// **Both notifiers below are `keepAlive: true`, not the `@riverpod` default.**
/// This is app-global selection state — task 10.2 set the same precedent for
/// `ServerConfigNotifier` — and callers legitimately mutate them via a bare
/// `ref.read(...).notifier).set(...)` with no active watcher at the call site
/// (`CurrentSession.completeSignIn`, `app_context_provider.dart`'s
/// auto-create path, several `More` screens). An `autoDispose` notifier with
/// no listener can be torn down by Riverpod the instant its refcount hits
/// zero — which a bare `read` can trigger immediately — and if that lands
/// while `set()` is suspended on its `await _prefs.setString(...)`, the
/// `state = AsyncData(...)` assignment after it throws "Cannot use the Ref
/// of ... after it has been disposed." **This happened on a real device**
/// (task 10.4's phone-on-LAN check), crashing inside `completeSignIn`. It did
/// not reproduce in a plain `ProviderContainer` unit test even with a real
/// `Future.delayed` standing in for the network round trip — Riverpod's
/// disposal scheduling goes through a `Vsync` that a widget-bound
/// `ProviderScope` supplies (frame callbacks) and a bare container falls back
/// to a zero-duration `Timer`, so the two don't race identically. `keepAlive`
/// removes the possibility outright rather than depending on reproducing or
/// reasoning about that timing, in either environment.
final class ActiveProjectIdProvider
    extends $AsyncNotifierProvider<ActiveProjectId, String?> {
  /// Persisted IDs only, for now. Phase 1 adds `currentProjectProvider` /
  /// `currentUserProvider` that resolve these IDs to full `Project`/`User`
  /// rows via the repositories built in that phase — screens should migrate
  /// to those once available rather than re-deriving objects from the ID here.
  ///
  /// **Both notifiers below are `keepAlive: true`, not the `@riverpod` default.**
  /// This is app-global selection state — task 10.2 set the same precedent for
  /// `ServerConfigNotifier` — and callers legitimately mutate them via a bare
  /// `ref.read(...).notifier).set(...)` with no active watcher at the call site
  /// (`CurrentSession.completeSignIn`, `app_context_provider.dart`'s
  /// auto-create path, several `More` screens). An `autoDispose` notifier with
  /// no listener can be torn down by Riverpod the instant its refcount hits
  /// zero — which a bare `read` can trigger immediately — and if that lands
  /// while `set()` is suspended on its `await _prefs.setString(...)`, the
  /// `state = AsyncData(...)` assignment after it throws "Cannot use the Ref
  /// of ... after it has been disposed." **This happened on a real device**
  /// (task 10.4's phone-on-LAN check), crashing inside `completeSignIn`. It did
  /// not reproduce in a plain `ProviderContainer` unit test even with a real
  /// `Future.delayed` standing in for the network round trip — Riverpod's
  /// disposal scheduling goes through a `Vsync` that a widget-bound
  /// `ProviderScope` supplies (frame callbacks) and a bare container falls back
  /// to a zero-duration `Timer`, so the two don't race identically. `keepAlive`
  /// removes the possibility outright rather than depending on reproducing or
  /// reasoning about that timing, in either environment.
  ActiveProjectIdProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'activeProjectIdProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$activeProjectIdHash();

  @$internal
  @override
  ActiveProjectId create() => ActiveProjectId();
}

String _$activeProjectIdHash() => r'1ac9d234294a11e5a304c57ae55b5b4bf0e3a248';

/// Persisted IDs only, for now. Phase 1 adds `currentProjectProvider` /
/// `currentUserProvider` that resolve these IDs to full `Project`/`User`
/// rows via the repositories built in that phase — screens should migrate
/// to those once available rather than re-deriving objects from the ID here.
///
/// **Both notifiers below are `keepAlive: true`, not the `@riverpod` default.**
/// This is app-global selection state — task 10.2 set the same precedent for
/// `ServerConfigNotifier` — and callers legitimately mutate them via a bare
/// `ref.read(...).notifier).set(...)` with no active watcher at the call site
/// (`CurrentSession.completeSignIn`, `app_context_provider.dart`'s
/// auto-create path, several `More` screens). An `autoDispose` notifier with
/// no listener can be torn down by Riverpod the instant its refcount hits
/// zero — which a bare `read` can trigger immediately — and if that lands
/// while `set()` is suspended on its `await _prefs.setString(...)`, the
/// `state = AsyncData(...)` assignment after it throws "Cannot use the Ref
/// of ... after it has been disposed." **This happened on a real device**
/// (task 10.4's phone-on-LAN check), crashing inside `completeSignIn`. It did
/// not reproduce in a plain `ProviderContainer` unit test even with a real
/// `Future.delayed` standing in for the network round trip — Riverpod's
/// disposal scheduling goes through a `Vsync` that a widget-bound
/// `ProviderScope` supplies (frame callbacks) and a bare container falls back
/// to a zero-duration `Timer`, so the two don't race identically. `keepAlive`
/// removes the possibility outright rather than depending on reproducing or
/// reasoning about that timing, in either environment.

abstract class _$ActiveProjectId extends $AsyncNotifier<String?> {
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

@ProviderFor(ActiveUserId)
final activeUserIdProvider = ActiveUserIdProvider._();

final class ActiveUserIdProvider
    extends $AsyncNotifierProvider<ActiveUserId, String?> {
  ActiveUserIdProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'activeUserIdProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$activeUserIdHash();

  @$internal
  @override
  ActiveUserId create() => ActiveUserId();
}

String _$activeUserIdHash() => r'203a0a25b001dd261c726930328948aa652a9211';

abstract class _$ActiveUserId extends $AsyncNotifier<String?> {
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
